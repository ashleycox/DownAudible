"""Audible operations for the macOS app, using mkb79's Audible and Audible CLI."""

import asyncio
import contextlib
import errno
import json
import logging
import math
import os
import re
import sys
from datetime import UTC, datetime
from http.client import HTTPException
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener

import audible
import httpx
from audible.activation_bytes import extract_activation_bytes
from audible.aescipher import AESCipher, detect_file_encryption
from audible.client import default_response_callback
from audible.exceptions import (
    AuthFlowError,
    NoRefreshToken,
    NotFoundError,
    NotResponding,
    RequestError,
    StatusError,
    Unauthorized,
)
from audible.localization import Locale
from audible.login import build_oauth_url, create_code_verifier
from audible.register import register
from audible_cli.config import ConfigFile
from audible_cli.constants import (
    AVAILABLE_MARKETPLACES,
)
from audible_cli.exceptions import (
    AudibleCliException,
    LicenseDenied,
    NoDownloadUrl,
    NotDownloadableAsAAX,
)
from audible_cli.models import Catalog, Library, LibraryItem, Wishlist
from audible_cli.utils import parse_api_datetime
from bs4 import BeautifulSoup
from download_transfer import (
    FormatUnavailable,
    OperationError,
    PartsRequired,
    fingerprint,
    stream_file,
)

WIRE = sys.stdout
AUTHORIZATION_CODE = "openid.oa2.authorization_code"
ACTIVATION_CODE = re.compile(r"[0-9a-fA-F]{8}")
PAGE_SIZE = 100
DOWNLOAD_USER_AGENT = "Audible/671 CFNetwork/1240.0.4 Darwin/20.6.0"
CATALOG_FIELDS = (
    "contributors, media, product_attrs, product_desc, product_extended_attrs, "
    "series, rating, categories, category_ladders, relationships"
)


def emit(**message):
    print(
        json.dumps(message, ensure_ascii=True, separators=(",", ":")),
        file=WIRE,
        flush=True,
    )


def begin_sign_in(request):
    locale = Locale(country_code=request["marketplace"])
    verifier = create_code_verifier()
    url, serial = build_oauth_url(
        country_code=locale.country_code,
        domain=locale.domain,
        market_place_id=locale.market_place_id,
        code_verifier=verifier,
        with_username=request.get("legacyUsername", False),
    )
    return {"url": url, "serial": serial, "verifier": verifier.decode("ascii")}


def complete_sign_in(request):
    locale = Locale(country_code=request["marketplace"])
    legacy = request.get("legacyUsername", False)
    host = "audible" if legacy else "amazon"
    redirect = urlsplit(request["redirect"])
    codes = parse_qs(redirect.query).get(AUTHORIZATION_CODE, [])
    if (
        redirect.scheme != "https"
        or redirect.netloc.lower() != f"www.{host}.{locale.domain}"
        or redirect.path.rstrip("/") != "/ap/maplanding"
        or len(codes) != 1
    ):
        raise OperationError("invalidRedirect")
    try:
        credentials = register(
            authorization_code=codes[0],
            code_verifier=request["verifier"].encode("ascii"),
            domain=locale.domain,
            serial=request["serial"],
            with_username=legacy,
        )
    except httpx.RequestError:
        raise
    except Exception as error:
        raise OperationError("signInFailed") from error
    credentials["locale_code"] = locale.country_code
    credentials["with_username"] = legacy
    auth = audible.Authenticator.from_dict(credentials)
    return {"session": session_json(auth)}


def session_json(auth):
    return json.dumps(auth.to_dict(), separators=(",", ":"))


class NoActivationRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def get_activation_bytes(auth, refresh, timeout):
    activation = auth.activation_bytes
    if (
        not refresh
        and isinstance(activation, str)
        and ACTIVATION_CODE.fullmatch(activation)
    ):
        return activation
    if "signing" not in auth.available_auth_modes:
        raise OperationError("activation")

    url = httpx.URL(
        "https://www.audible.com/license/token",
        params={
            "player_manuf": "Audible,iPhone",
            "action": "register",
            "player_model": "iPhone",
        },
    )
    try:
        # The legacy activation route can reject HTTPX with a CloudFront 403.
        # Keep the same signing and TLS trust when sending it through urllib.
        with contextlib.closing(auth.sync_auth_flow(httpx.Request("GET", url))) as flow:
            signed = next(flow)
            request = Request(str(signed.url), headers=dict(signed.headers))
        opener = build_opener(
            NoActivationRedirect(), HTTPSHandler(context=httpx.create_ssl_context())
        )
        with opener.open(request, timeout=timeout) as response:
            activation = extract_activation_bytes(response.read())
    except HTTPError as error:
        error.close()
        raise OperationError("activation") from error
    except (HTTPException, OSError) as error:
        raise OperationError("network") from error
    except Exception as error:
        raise OperationError("activation") from error
    if not ACTIVATION_CODE.fullmatch(activation):
        raise OperationError("activation")
    auth.activation_bytes = activation
    return activation


def auth_encoding(path):
    if not path.is_file():
        raise OperationError("authImport")
    size = path.stat().st_size
    if not 0 < size <= 1024 * 1024:
        raise OperationError("authImport")
    try:
        encoding = detect_file_encryption(path)
    except TypeError as error:
        raise OperationError("authImport") from error
    # A binary export contains a salt block, an IV block and ciphertext blocks.
    if encoding is None or (encoding == "bytes" and (size < 48 or size % 16)):
        raise OperationError("authImport")
    return encoding


def cli_profiles(request):
    try:
        config = ConfigFile(Path(request["file"]))
        primary = config.app_config.get("primary_profile")
        profiles = []
        for name in config.data.get("profile", {}):
            filename = config.get_profile_option(name, "auth_file")
            if not isinstance(filename, str):
                continue
            auth_file = (config.dirname / Path(filename).expanduser()).resolve()
            try:
                encryption = auth_encoding(auth_file)
            except (OSError, OperationError):
                continue
            marketplace = config.get_profile_option(name, "country_code")
            profiles.append(
                {
                    "name": name,
                    "authFile": auth_file.as_uri(),
                    "marketplace": marketplace
                    if marketplace in AVAILABLE_MARKETPLACES
                    else None,
                    "isDefault": name == primary,
                    "requiresPassword": bool(encryption),
                }
            )
        if profiles:
            return sorted(
                profiles,
                key=lambda profile: (
                    not profile["isDefault"],
                    profile["name"].casefold(),
                ),
            )
    except Exception as error:
        raise OperationError("cliConfig") from error
    raise OperationError("cliConfig")


def import_auth_file(request):
    path = Path(request["file"])
    encryption = auth_encoding(path)
    password = request.get("password")
    if encryption and not password:
        raise OperationError("importPassword")
    try:
        plaintext = (
            AESCipher(password).from_file(path, encryption)
            if encryption
            else path.read_text()
        )
        values = json.loads(plaintext)
    except OSError:
        raise
    except Exception as error:
        raise OperationError(
            "importPasswordIncorrect" if encryption else "authImport"
        ) from error
    if not isinstance(values, dict):
        raise OperationError("authImport")
    marketplace = request.get("marketplace") or values.get("locale_code")
    if marketplace not in AVAILABLE_MARKETPLACES:
        raise OperationError("importMarketplace")
    supported_keys = audible.Authenticator().to_dict().keys() | {"login_cookies"}
    values = {key: value for key, value in values.items() if key in supported_keys}
    try:
        auth = audible.Authenticator.from_dict(values, locale=marketplace)
        if "signing" not in auth.available_auth_modes:
            raise OperationError("authImport")
    except (AttributeError, TypeError, ValueError) as error:
        raise OperationError("authImport") from error
    return {"session": session_json(auth), "marketplace": auth.locale.country_code}


def image_url(item):
    pictures = image_urls(item)
    return pictures[max(pictures, key=int)] if pictures else None


def image_urls(item):
    return {
        str(size): url
        for size, url in (item.product_images or {}).items()
        if str(size).isdecimal() and isinstance(url, str)
    }


def names(contributors):
    return [
        contributor["name"]
        for contributor in contributors or []
        if contributor.get("name")
    ]


def plain_text(text):
    return (
        BeautifulSoup(text, "html.parser").get_text(" ", strip=True) if text else None
    )


def numeric_value(value, convert):
    try:
        if value is not None:
            result = convert(value)
            return result if math.isfinite(result) else None
    except (TypeError, ValueError, OverflowError):
        pass
    return None


def represent_book(item):
    series = next(iter(item.series or []), {})
    duration_minutes = numeric_value(item.runtime_length_min, int)
    if duration_minutes is not None and not 0 <= duration_minutes <= sys.maxsize // 60:
        duration_minutes = None
    rights = item.customer_rights or {}
    unavailable_reason = None
    if item.is_parent_podcast():
        unavailable_reason = "podcastSeries"
    elif not published_or_unknown(item):
        unavailable_reason = "unpublished"
    elif rights.get("is_consumable_offline") is False:
        unavailable_reason = "offlineRestricted"
    library_status = item.library_status or {}
    rating = (item.rating or {}).get("overall_distribution") or {}
    genres = (
        entry["name"]
        for category in item.category_ladders or []
        for entry in category.get("ladder") or []
        if entry.get("name")
    )
    return {
        "asin": item.asin,
        "title": item.title,
        "subtitle": item.subtitle,
        "authors": names(item.authors),
        "narrators": names(item.narrators),
        "series": series.get("title"),
        "seriesSequence": str(series["sequence"])
        if series.get("sequence") is not None
        else None,
        "publisher": item.publisher_name,
        "description": plain_text(item.publisher_summary or item.merchandising_summary),
        "language": item.language,
        "genres": list(dict.fromkeys(genres)),
        "releaseDate": item.release_date,
        "purchaseDate": item.purchase_date,
        "dateAdded": library_status.get("date_added") or item.added_timestamp,
        "rating": numeric_value(rating.get("display_average_rating"), float),
        "ratingCount": numeric_value(rating.get("num_ratings"), int),
        "isFinished": item.is_finished if isinstance(item.is_finished, bool) else None,
        "percentComplete": numeric_value(item.percent_complete, float),
        "durationSeconds": duration_minutes * 60
        if duration_minutes is not None
        else None,
        "coverURL": image_url(item),
        "coverImages": image_urls(item),
        "hasPDF": bool(item.pdf_url),
        "isDownloadable": unavailable_reason is None,
        "downloadUnavailableReason": unavailable_reason,
    }


def date_bounds(options):
    start, end = options.get("purchaseStart"), options.get("purchaseEnd")
    return (
        datetime.fromtimestamp(start, UTC) if start is not None else None,
        datetime.fromtimestamp(end, UTC) if end is not None else None,
    )


def published_or_unknown(item):
    try:
        return item.is_published()
    except ValueError:
        # Treat an invalid publication timestamp like an absent one.
        return True


def acquired_within(item, start, end):
    if start is None and end is None:
        return True
    acquired = item.purchase_date or (item.library_status or {}).get("date_added")
    if acquired is None:
        return True
    try:
        acquired = parse_api_datetime(acquired)
    except ValueError:
        return True
    return (start is None or start <= acquired) and (
        end is None or acquired <= end or item.is_parent_podcast()
    )


def cover_sizes(options):
    known_sizes = {252, 315, 360, 408, 500, 558, 570, 882, 900, 1215}
    return sorted(known_sizes.intersection(options.get("coverSizes", [])), reverse=True)


async def list_books(client, options):
    items = {}
    page = 1
    page_size = max(10, min(1000, options.get("pageSize", PAGE_SIZE)))
    start, end = date_bounds(options)
    pictures = ", ".join(str(size) for size in cover_sizes(options) or [1215, 500])
    params = (
        {"purchased_after": start.strftime("%Y-%m-%dT%H:%M:%S.%fZ")} if start else {}
    )
    while True:
        library, total = await Library.from_api(
            client,
            page=page,
            num_results=page_size,
            image_sizes=pictures,
            include_total_count_header=True,
            **params,
        )
        for item in library:
            if item.asin and item.title and acquired_within(item, start, end):
                items[item.asin] = item
        if (
            not library
            or (total and int(total) <= page * page_size)
            or (not total and len(library) < page_size)
        ):
            break
        page += 1

    mode = options.get("podcasts", "ignore")
    books = []
    for item in items.values():
        if mode == "ignore" and (
            item.content_type == "Podcast" or item.is_parent_podcast()
        ):
            continue
        if mode == "resolveEpisodes" and item.is_parent_podcast():
            # The CLI can fall back to the catalogue. Apply the range to either
            # source locally instead of sending library-only arguments there.
            episodes = await item.get_child_items(image_sizes=pictures)
            books.extend(
                represent_book(episode)
                for episode in episodes or []
                if episode.asin and episode.title and acquired_within(episode, start, end)
            )
        else:
            books.append(represent_book(item))
    return list({book["asin"]: book for book in books}.values())


async def library_item(client, asin, image_sizes=None):
    params = (
        {"image_sizes": ", ".join(str(size) for size in image_sizes)}
        if image_sizes
        else {}
    )
    response = await client.get(
        f"library/{asin}",
        response_groups="contributors, customer_rights, media, product_attrs, relationships, pdf_url",
        **params,
    )
    return LibraryItem(response, client)


def catalog_entries(items):
    books = {}
    for item in items:
        if item.asin and item.title:
            books[item.asin] = {
                **represent_book(item),
                "isDownloadable": False,
                "downloadUnavailableReason": None,
            }
    return list(books.values())


async def catalog_search(client, text):
    text = text.strip()
    if not text:
        return []
    if re.fullmatch(r"[A-Za-z0-9]{10}", text):
        try:
            response = await client.get(
                f"catalog/products/{text.upper()}",
                response_groups=CATALOG_FIELDS,
            )
        except NotFoundError:
            pass
        else:
            exact = catalog_entries(
                [LibraryItem(response.get("product") or {}, client)]
            )
            if exact:
                return exact
    matches = await Catalog.from_api(
        client,
        title=text[:200],
        num_results=50,
        response_groups=CATALOG_FIELDS,
    )
    return catalog_entries(matches)


async def edit_wishlist(client, command, asins):
    failed = {}
    # Audible can throttle bursts of Wishlist requests.
    for asin in dict.fromkeys(asins):
        if not re.fullmatch(r"[A-Za-z0-9]{10}", asin):
            failed[asin] = "invalidTitle"
            continue
        try:
            if command == "wishlistAdd":
                await client.post("wishlist", body={"asin": asin})
            else:
                await client.delete(f"wishlist/{asin}")
        except Unauthorized:
            raise
        except NotFoundError:
            if command == "wishlistAdd":
                failed[asin] = "notFound"
        except (RequestError, httpx.HTTPError) as error:
            failed[asin] = failure_code(error)
    return failed


def chapters_from(metadata):
    chapter_info = (metadata.get("content_metadata") or {}).get("chapter_info") or {}
    if chapter_info.get("is_accurate") is False:
        return []
    chapters = []
    for chapter in chapter_info.get("chapters") or []:
        if not isinstance(chapter, dict):
            continue
        start = chapter.get("start_offset_ms")
        duration = chapter.get("length_ms")
        title = chapter.get("title")
        if (
            type(start) is int
            and type(duration) is int
            and start >= 0
            and duration > 0
            and start + duration <= sys.maxsize
            and isinstance(title, str)
            and title.strip()
        ):
            chapters.append(
                {
                    "startMilliseconds": start,
                    "durationMilliseconds": duration,
                    "title": title,
                }
            )
    return sorted(chapters, key=lambda chapter: chapter["startMilliseconds"])


async def book_chapters(client, asin, quality):
    item = LibraryItem({"asin": asin}, client)
    try:
        metadata = await item.get_content_metadata(quality, chapter_type="Flat")
    except NotFoundError:
        return []
    return chapters_from(metadata)


def web_cookies(auth):
    cookies = httpx.Cookies()
    for key, value in (auth.website_cookies or {}).items():
        cookies.set(key, value, domain=f".audible.{auth.locale.domain}")
    return cookies


def check_license_response(response):
    if not response.request.url.path.endswith("/licenserequest"):
        return default_response_callback(response)

    if response.status_code in (400, 404):
        try:
            error = response.json()
        except ValueError:
            pass
        else:
            if isinstance(error, dict) and error.get("error_code") == "000307":
                raise OperationError("aaxcUnavailable")

    data = default_response_callback(response)
    content_license = data.get("content_license") if isinstance(data, dict) else None
    if not isinstance(content_license, dict) or not isinstance(
        content_license.get("status_code"), str
    ):
        raise OperationError("licenseResponse")
    if content_license["status_code"] == "Denied":
        reasons = content_license.get("license_denial_reasons")
        if isinstance(reasons, list):
            if any(
                isinstance(reason, dict)
                and reason.get("rejectionReason") == "CustomerThrottled"
                for reason in reasons
            ):
                raise OperationError("licenseThrottled")
            if reasons and all(
                isinstance(reason, dict)
                and reason.get("rejectionReason") == "RequesterEligibility"
                and reason.get("validationType") in ("Ownership", "Membership", "AYCL")
                for reason in reasons
            ):
                raise OperationError("licenseEntitlement")
        raise OperationError("licenseDenied")
    return data


def conversion_credentials(license_response):
    voucher = license_response.get("content_license", {}).get("license_response", {})
    if not isinstance(voucher, dict):
        return {}
    key = voucher.get("key")
    iv = voucher.get("iv")
    if all(
        isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{32}", value)
        for value in (key, iv)
    ):
        return {"contentKey": key, "contentIV": iv}
    return {}


async def download_audio(item, client, web, folder, progress, options):
    if (
        not isinstance(item.asin, str)
        or not re.fullmatch(r"[A-Za-z0-9]{10}", item.asin)
    ):
        raise OperationError("unavailable")
    if not item.is_published():
        raise OperationError("notPublished")
    rights = item.customer_rights or {}
    if not rights.get("is_consumable_offline", True):
        raise OperationError("offlineRestricted")
    has_parts = item.content_delivery_type == "MultiPartBook"
    if has_parts and "is_consumable_offline" not in rights:
        # The download URL providers require explicit offline rights for their item.
        raise PartsRequired()
    quality = options.get("quality", "best")
    mode = options.get("format", "preferAAX")
    bandwidth = max(0, options.get("bytesPerSecond", 0))
    aax_providers = (
        () if mode == "aaxcOnly" else (item.get_aax_url_old, item.get_aax_url)
    )
    for find_aax_url in aax_providers:
        try:
            url, codec = await find_aax_url(quality)
            target = await stream_file(
                web,
                url,
                folder / (item.asin + ".aax"),
                "aax",
                progress,
                api=client,
                bandwidth=bandwidth,
                representation=fingerprint("aax", quality, codec),
            )
            return {
                "file": target.path.name,
                "asin": item.asin,
                "credentials": {},
                "originalFilename": target.original_filename,
            }
        except NotDownloadableAsAAX:
            break
        except PartsRequired:
            has_parts = True
        except (AudibleCliException, FormatUnavailable):
            continue

    if mode == "aaxOnly":
        if has_parts:
            raise PartsRequired()
        raise OperationError("aaxUnavailable")
    try:
        url, codec, voucher = await item.get_aaxc_url(quality)
        extension = "mp3" if codec.lower() == "mpeg" else "aaxc"
        credentials = conversion_credentials(voucher)
        representation = (
            fingerprint(extension, quality, codec, credentials)
            if credentials or extension == "mp3"
            else None
        )
        target = await stream_file(
            web,
            url,
            folder / (item.asin + "." + extension),
            extension,
            progress,
            api=client,
            bandwidth=bandwidth,
            representation=representation,
        )
    except (NoDownloadUrl, NotFoundError, OperationError) as error:
        if has_parts and (
            failure_code(error) in ("aaxcUnavailable", "notFound", "downloadResponse")
            or (isinstance(error, FormatUnavailable) and error.status_code in (404, 410))
        ):
            raise PartsRequired() from error
        raise
    return {
        "file": target.path.name,
        "asin": item.asin,
        "credentials": credentials,
    }


async def resolve_parts(item):
    library = await item.get_child_items() or []
    parts = [part for part in library if part.content_delivery_type == "AudioPart"]
    if not parts:
        raise OperationError("partsUnavailable")
    return parts


async def download_book(client, web, asin, folder, options):
    item = await library_item(client, asin)
    try:
        result = await download_audio(
            item,
            client,
            web,
            folder,
            lambda progress: emit(progress=progress),
            options,
        )
        return {"parts": [result]}
    except PartsRequired:
        parts = await resolve_parts(item)

    results = []
    for index, part in enumerate(parts):

        def report_progress(progress, part_index=index):
            emit(progress=(part_index + progress) / len(parts))

        results.append(
            await download_audio(part, client, web, folder, report_progress, options)
        )
    return {"parts": results}


async def cover_urls(client, request, options):
    sizes = cover_sizes(options)
    if not sizes:
        if request.get("coverURL"):
            return [("cover", request["coverURL"])]
        item = await library_item(client, request["asin"], [1215, 500])
        return [("cover", image_url(item))]
    images = request.get("coverImages") or {}
    if any(str(size) not in images for size in sizes):
        item = await library_item(client, request["asin"], sizes)
        images = {**images, **image_urls(item)}
    return [(f"cover-{size}", images.get(str(size))) for size in sizes]


async def download_extras(client, web, request, options):
    folder = Path(request["directory"])
    asin = request["asin"]
    result = {"covers": [], "failed": {}}
    failed = result["failed"]
    bandwidth = max(0, options.get("bytesPerSecond", 0))
    if request.get("cover"):
        try:
            urls = await cover_urls(client, request, options)
        except Unauthorized:
            raise
        except RequestError as error:
            failed["cover"] = failure_code(error, "extras")
            urls = []
        for basename, url in urls:
            if url is None:
                continue
            try:
                # Artwork is public. The image host only sees an unsigned request.
                cover = await stream_file(
                    web, url, folder / basename, "cover", bandwidth=bandwidth
                )
                result["covers"].append(cover.path.name)
            except (httpx.HTTPError, OperationError, OSError) as error:
                failed.setdefault("cover", failure_code(error, "extras"))
        if not urls or any(url is None for _, url in urls):
            failed.setdefault("cover", "extraUnavailable")
    if request.get("pdf"):
        try:
            url = (
                f"https://www.audible.{client.auth.locale.domain}/companion-file/{asin}"
            )
            pdf = await stream_file(
                web,
                url,
                folder / "companion.pdf",
                "pdf",
                api=client,
                bandwidth=bandwidth,
            )
            result["pdf"] = pdf.path.name
        except (httpx.HTTPError, OperationError, OSError) as error:
            failed["PDF"] = failure_code(error, "extras")
    return result


async def download_json_extras(client, request, options):
    folder = Path(request["directory"])
    item = LibraryItem({"asin": request["asin"]}, client)
    result = {"failed": {}}
    if request.get("chapters"):
        try:
            metadata = await item.get_content_metadata(
                options.get("quality", "best"),
                chapter_type=options.get("chapterStyle", "tree").capitalize(),
            )
            filename = "chapters.json"
            (folder / filename).write_text(
                json.dumps(metadata, ensure_ascii=False, indent=2) + "\n"
            )
            result["chapters"] = filename
        except Unauthorized:
            raise
        except (httpx.HTTPError, RequestError, AudibleCliException, OSError) as error:
            result["failed"]["chapters"] = failure_code(error, "jsonExtras")
    if request.get("annotations"):
        try:
            annotations = await item.get_annotations()
            filename = "annotations.json"
            (folder / filename).write_text(
                json.dumps(annotations, ensure_ascii=False, indent=2) + "\n"
            )
            result["annotations"] = filename
        except Unauthorized:
            raise
        except (httpx.HTTPError, RequestError, AudibleCliException, OSError) as error:
            result["failed"]["annotations"] = failure_code(error, "jsonExtras")
    return result


async def execute(request):
    command = request["command"]
    if command == "beginSignIn":
        return begin_sign_in(request)
    if command == "completeSignIn":
        return complete_sign_in(request)
    if command == "cliProfiles":
        return cli_profiles(request)
    if command == "inspectAuthFile":
        return bool(auth_encoding(Path(request["file"])))
    if command == "importAuthFile":
        return import_auth_file(request)

    options = request.get("options") or {}
    timeout = max(0, min(600, options.get("timeout", 45))) or None
    quality = options.get("quality", "best")
    auth = audible.Authenticator.from_dict(json.loads(request["session"]))
    if command == "exportAuthFile":
        password = request.get("password")
        if not password:
            raise OperationError("exportPassword")
        encrypted = AESCipher(password, kdf_iterations=65535).to_dict(
            session_json(auth)
        )
        return json.dumps(encrypted, indent=2) + "\n"
    if command == "activation":
        activation = get_activation_bytes(
            auth, request.get("refreshActivation", False), timeout
        )
        return {
            "activationBytes": activation,
            "session": session_json(auth),
        }

    async with audible.AsyncClient(
        auth,
        cookies=web_cookies(auth),
        timeout=timeout,
        headers={"Accept-Encoding": "identity", "User-Agent": DOWNLOAD_USER_AGENT},
        response_callback=check_license_response,
    ) as client:
        if command == "library":
            return await list_books(client, options)
        if command == "wishlist":
            items = await Wishlist.from_api(client, response_groups=CATALOG_FIELDS)
            return catalog_entries(items)
        if command == "catalog":
            return await catalog_search(client, request["query"])
        if command in ("wishlistAdd", "wishlistRemove"):
            return await edit_wishlist(client, command, request["asins"])
        asin = request["asin"]
        if not re.fullmatch(r"[A-Za-z0-9]{10}", asin):
            raise OperationError("unavailable")
        if command == "chapters":
            return await book_chapters(client, asin, quality)
        if command == "jsonExtras":
            return await download_json_extras(client, request, options)
        if command == "voucher":
            item = await library_item(client, asin)
            voucher = await item.get_license(quality)
            return conversion_credentials(voucher)
        async with httpx.AsyncClient(
            headers={"Accept-Encoding": "identity"}, timeout=timeout
        ) as web:
            if command == "download":
                return await download_book(
                    client, web, asin, Path(request["directory"]), options
                )
            if command == "extras":
                return await download_extras(client, web, request, options)
    raise OperationError("service")


def failure_code(error, command=None):
    if isinstance(error, OperationError):
        return error.code
    if isinstance(error, LicenseDenied):
        return "licenseDenied"
    if isinstance(error, NoDownloadUrl):
        return "aaxcUnavailable"
    if isinstance(error, PartsRequired):
        return "partsUnavailable"
    if isinstance(error, (AuthFlowError, NoRefreshToken)):
        return "authorization"
    if isinstance(error, (StatusError, httpx.HTTPStatusError)):
        status = error.response.status_code
        if 500 <= status < 600:
            return "serverUnavailable"
        return {
            401: "authorization",
            403: "requestRejected",
            404: "notFound",
            429: "rateLimited",
        }.get(status, "requestRejected")
    if isinstance(error, (httpx.TimeoutException, NotResponding)):
        return "timeout"
    if isinstance(error, (httpx.RequestError, RequestError)):
        return "network"
    if isinstance(error, OSError):
        if error.errno in (errno.ENOSPC, errno.EDQUOT):
            return "diskFull"
        if command in ("download", "extras", "jsonExtras"):
            return "stagingFileAccess"
        return "fileAccess"
    return "service"


def main():
    logging.disable(logging.CRITICAL)
    # Upstream occasionally prints raw responses on failure. Only emit safe protocol messages.
    with (
        open(os.devnull, "w") as discard,
        contextlib.redirect_stdout(discard),
        contextlib.redirect_stderr(discard),
    ):
        request = {}
        try:
            request = json.load(sys.stdin)
            emit(result=asyncio.run(execute(request)))
        except Exception as error:  # noqa: BLE001 - upstream exceptions can contain authentication data
            command = request.get("command") if isinstance(request, dict) else None
            emit(error=failure_code(error, command))


if __name__ == "__main__":
    main()

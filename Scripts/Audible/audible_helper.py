"""Audible operations for the macOS app, using mkb79's Audible and Audible CLI."""

import asyncio
import contextlib
import json
import logging
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import audible
import httpx
from audible.aescipher import AESCipher, detect_file_encryption
from audible.exceptions import NotFoundError, RequestError, Unauthorized
from audible.localization import Locale
from audible.login import build_oauth_url, create_code_verifier
from audible.register import register
from audible_cli.config import ConfigFile
from audible_cli.constants import (
    AAX_CONTENT_TYPES,
    AAXC_CONTENT_TYPES,
    AVAILABLE_MARKETPLACES,
)
from audible_cli.exceptions import (
    AudibleCliException,
    LicenseDenied,
    NoDownloadUrl,
    NotDownloadableAsAAX,
)
from audible_cli.models import Library, LibraryItem
from audible_cli.utils import parse_api_datetime
from bs4 import BeautifulSoup

WIRE = sys.stdout
AUTHORIZATION_CODE = "openid.oa2.authorization_code"
CHUNK_SIZE = 256 * 1024
PAGE_SIZE = 100
DOWNLOAD_USER_AGENT = "Audible/671 CFNetwork/1240.0.4 Darwin/20.6.0"


class OperationError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class PartsRequired(Exception):
    pass


class FormatUnavailable(Exception):
    pass


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


def auth_encoding(path):
    if not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise OperationError("authImport")
    encoding = detect_file_encryption(path)
    if encoding is None:
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
            "importPassword" if encryption else "authImport"
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


def represent_book(item):
    series = next(iter(item.series or []), {})
    duration_minutes = item.runtime_length_min
    rights = item.customer_rights or {}
    library_status = item.library_status or {}
    genres = (
        entry["name"]
        for category in item.category_ladders or []
        for entry in category.get("ladder", [])
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
        "dateAdded": library_status.get("date_added"),
        "durationSeconds": int(duration_minutes) * 60
        if duration_minutes is not None
        else None,
        "coverURL": image_url(item),
        "coverImages": image_urls(item),
        "hasPDF": bool(item.pdf_url),
        "isDownloadable": not item.is_parent_podcast()
        and rights.get("is_consumable_offline") is not False
        and item.is_published(),
    }


def date_bounds(options):
    start, end = options.get("purchaseStart"), options.get("purchaseEnd")
    return (
        datetime.fromtimestamp(start, UTC) if start is not None else None,
        datetime.fromtimestamp(end, UTC) if end is not None else None,
    )


def acquired_within(item, start, end):
    if start is None and end is None:
        return True
    acquired = item.purchase_date or (item.library_status or {}).get("date_added")
    if acquired is None:
        return True
    acquired = parse_api_datetime(acquired)
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
            episodes = await item.get_child_items(
                start_date=start, end_date=end, image_sizes=pictures
            )
            books.extend(
                represent_book(episode)
                for episode in episodes or []
                if episode.asin and episode.title
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


def chapters_from(metadata):
    chapter_info = (metadata.get("content_metadata") or {}).get("chapter_info") or {}
    if chapter_info.get("is_accurate") is False:
        return []
    chapters = []
    for chapter in chapter_info.get("chapters", []):
        start = chapter.get("start_offset_ms")
        duration = chapter.get("length_ms")
        title = chapter.get("title")
        if (
            isinstance(start, int)
            and isinstance(duration, int)
            and start >= 0
            and duration > 0
            and title
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


def artifact_matches(prefix, content_type, kind):
    if kind == "aax":
        return (
            content_type in (*AAX_CONTENT_TYPES, "application/octet-stream")
            and prefix[4:8] == b"ftyp"
        )
    if kind == "aaxc":
        return (
            content_type in (*AAXC_CONTENT_TYPES, "application/octet-stream")
            and prefix[4:8] == b"ftyp"
        )
    if kind == "mp3":
        return content_type in (*AAXC_CONTENT_TYPES, "application/octet-stream") and (
            prefix.startswith(b"ID3")
            or (len(prefix) >= 2 and prefix[0] == 0xFF and prefix[1] & 0xE0 == 0xE0)
        )
    if kind == "pdf":
        return b"%PDF-" in prefix[:1024]
    return image_extension(prefix) is not None


def image_extension(prefix):
    if prefix.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if prefix.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if prefix.startswith(b"RIFF") and prefix[8:12] == b"WEBP":
        return "webp"
    if prefix.startswith((b"GIF87a", b"GIF89a")):
        return "gif"
    return None


@contextlib.asynccontextmanager
async def artifact_response(web, url, api):
    url = httpx.URL(url)
    trusted = set()
    if api is not None:
        domain = api.auth.locale.domain
        trusted = {f"{service}.audible.{domain}" for service in ("www", "cds", "api")}

    for _ in range(10):
        if (
            url.scheme != "https"
            or url.username
            or url.password
            or url.port not in (None, 443)
        ):
            raise FormatUnavailable()
        client = api.session if url.host in trusted else web
        # The CDN URL normally contains its own token. Keep account signing
        # headers on Audible's hosts when a response redirects to the CDN.
        async with client.stream("GET", url, follow_redirects=False) as response:
            if response.has_redirect_location:
                url = response.url.join(response.headers["location"])
            else:
                yield response
                return
    raise OperationError("network")


async def stream_file(web, url, target, kind, progress=None, *, api=None, bandwidth=0):
    async with artifact_response(web, url, api) as response:
        if response.status_code in (400, 403, 404, 410):
            raise FormatUnavailable()
        response.raise_for_status()
        chunk_size = (
            min(CHUNK_SIZE, max(4096, bandwidth // 4)) if bandwidth else CHUNK_SIZE
        )
        iterator = response.aiter_bytes(chunk_size=chunk_size)
        first = await anext(iterator, b"")
        content_type = (
            response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        )
        if not artifact_matches(first, content_type, kind):
            if b"please download individual parts" in first.lower():
                raise PartsRequired()
            raise FormatUnavailable()

        if kind == "cover":
            target = target.with_suffix("." + image_extension(first))
        intermediate = target.with_name(target.name + ".partial")
        length = response.headers.get("content-length", "")
        expected = (
            int(length)
            if length.isdecimal()
            and response.headers.get("content-encoding", "identity") == "identity"
            else 0
        )
        written = 0
        last_update = -1
        now = asyncio.get_running_loop().time
        started = now()

        try:
            with intermediate.open("xb") as output:
                data = first
                while data:
                    output.write(data)
                    written += len(data)
                    if bandwidth:
                        delay = started + written / bandwidth - now()
                        if delay > 0:
                            await asyncio.sleep(delay)
                    if progress and expected:
                        percent = min(99, int(written * 100 / expected))
                        if percent > last_update:
                            progress(percent / 100)
                            last_update = percent
                    data = await anext(iterator, b"")
            if expected and written != expected:
                raise OperationError("network")
            intermediate.rename(target)
        finally:
            intermediate.unlink(missing_ok=True)

    if progress:
        progress(1.0)
    return target


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


async def download_part(item, client, web, folder, progress, options):
    if (
        not (item.customer_rights or {}).get("is_consumable_offline", True)
        or not item.is_published()
    ):
        raise OperationError("unavailable")
    quality = options.get("quality", "best")
    mode = options.get("format", "preferAAX")
    bandwidth = max(0, options.get("bytesPerSecond", 0))
    aax_providers = (
        () if mode == "aaxcOnly" else (item.get_aax_url_old, item.get_aax_url)
    )
    for find_aax_url in aax_providers:
        try:
            url, _ = await find_aax_url(quality)
            target = await stream_file(
                web,
                url,
                folder / (item.asin + ".aax"),
                "aax",
                progress,
                api=client,
                bandwidth=bandwidth,
            )
            return {"file": target.name, "asin": item.asin, "credentials": {}}
        except NotDownloadableAsAAX:
            break
        except (AudibleCliException, FormatUnavailable):
            continue

    if mode == "aaxOnly":
        raise OperationError("unavailable")
    url, codec, voucher = await item.get_aaxc_url(quality)
    extension = "mp3" if codec.lower() == "mpeg" else "aaxc"
    target = await stream_file(
        web,
        url,
        folder / (item.asin + "." + extension),
        extension,
        progress,
        api=client,
        bandwidth=bandwidth,
    )
    return {
        "file": target.name,
        "asin": item.asin,
        "credentials": conversion_credentials(voucher),
    }


async def resolve_parts(item):
    library = await item.get_child_items() or []
    parts = [part for part in library if part.content_delivery_type == "AudioPart"]
    if not parts:
        raise OperationError("unavailable")
    return parts


async def download_book(client, web, asin, folder, options):
    item = await library_item(client, asin)
    if item.content_delivery_type == "MultiPartBook":
        parts = await resolve_parts(item)
    else:
        try:
            result = await download_part(
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
            await download_part(part, client, web, folder, report_progress, options)
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
    result = {"covers": [], "failed": []}
    bandwidth = max(0, options.get("bytesPerSecond", 0))
    if request.get("cover"):
        try:
            urls = await cover_urls(client, request, options)
        except Unauthorized:
            raise
        except RequestError:
            urls = []
        if not urls or any(url is None for _, url in urls):
            result["failed"].append("cover")
        for basename, url in urls:
            if url is None:
                continue
            try:
                # Artwork is public. The image host only sees an unsigned request.
                cover = await stream_file(
                    web, url, folder / basename, "cover", bandwidth=bandwidth
                )
                result["covers"].append(cover.name)
            except (FormatUnavailable, httpx.HTTPError, OperationError):
                if "cover" not in result["failed"]:
                    result["failed"].append("cover")
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
            result["pdf"] = pdf.name
        except (FormatUnavailable, httpx.HTTPError, OperationError):
            result["failed"].append("PDF")
    return result


async def download_json_extras(client, request, options):
    folder = Path(request["directory"])
    item = LibraryItem({"asin": request["asin"]}, client)
    result = {"failed": []}
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
        except (httpx.HTTPError, RequestError):
            result["failed"].append("chapters")
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
        except (httpx.HTTPError, RequestError):
            result["failed"].append("annotations")
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
    if command == "activation":
        try:
            activation = auth.get_activation_bytes()
        except httpx.RequestError:
            raise
        except Exception as error:
            raise OperationError("activation") from error
        if not re.fullmatch(r"[0-9a-fA-F]{8}", activation):
            raise OperationError("activation")
        return {
            "activationBytes": activation,
            "session": session_json(auth),
        }

    async with audible.AsyncClient(
        auth,
        cookies=web_cookies(auth),
        timeout=timeout,
        headers={"Accept-Encoding": "identity", "User-Agent": DOWNLOAD_USER_AGENT},
    ) as client:
        if command == "library":
            return await list_books(client, options)
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


def main():
    logging.disable(logging.CRITICAL)
    # Upstream occasionally prints raw responses on failure. Only emit safe protocol messages.
    with (
        open(os.devnull, "w") as discard,
        contextlib.redirect_stdout(discard),
        contextlib.redirect_stderr(discard),
    ):
        try:
            result = asyncio.run(execute(json.load(sys.stdin)))
            emit(result=result)
        except OperationError as error:
            emit(error=error.code)
        except Unauthorized:
            emit(error="authorization")
        except (
            NotFoundError,
            FormatUnavailable,
            PartsRequired,
            LicenseDenied,
            NoDownloadUrl,
        ):
            emit(error="unavailable")
        except httpx.HTTPStatusError as error:
            emit(
                error="authorization"
                if error.response.status_code == 401
                else "network"
            )
        except (httpx.RequestError, RequestError):
            emit(error="network")
        except OSError:
            emit(error="fileAccess")
        except Exception:  # noqa: BLE001 - upstream exceptions can contain authentication data
            emit(error="service")


if __name__ == "__main__":
    main()

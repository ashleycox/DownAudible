"""Account and title reports. Only allowlisted metadata crosses the app pipe."""

import re
from datetime import datetime
from decimal import Decimal, InvalidOperation

import httpx
from audible.exceptions import AuthFlowError, NoRefreshToken, RequestError, StatusError
from audible.utils import build_access_token_header
from audible_cli.exceptions import AudibleCliException

from android_sign_in import ANDROID_DEVICE_TYPE, refresh_android_access_token
from download_transfer import OperationError

FORMATS = ("aax", "aaxc", "widevine")
PAUSE_CODES = {"authorization", "rateLimited", "licenseThrottled"}
ANDROID_AND_IPHONE = {ANDROID_DEVICE_TYPE: "android", "A2CZJZGLK2JJVM": "iphone"}
MONTH = re.compile(r"\d{4}-(0[1-9]|1[0-2])", re.ASCII)
CODEC = re.compile(r"[A-Za-z0-9._+-]{1,48}", re.ASCII)
MAX_DURATION_MS = 2**53 - 1
OFFER_ERRORS = (
    OperationError,
    AudibleCliException,
    AuthFlowError,
    NoRefreshToken,
    RequestError,
    StatusError,
    httpx.HTTPError,
    KeyError,
    TypeError,
    ValueError,
)


def device_registration(auth):
    data = auth.device_info
    info = data if isinstance(data, dict) else {}
    device_type = info.get("device_type")
    kind = (
        ANDROID_AND_IPHONE.get(device_type, "unknown")
        if isinstance(device_type, str)
        else "unknown"
    )
    result = {"marketplace": auth.locale.country_code, "kind": kind}
    name = info.get("device_name")
    if isinstance(name, str):
        label = " ".join(name.split())[:120]
        if label and label.isprintable():
            result["name"] = label
    serial = info.get("device_serial_number")
    if isinstance(serial, str) and re.fullmatch(r"[A-Za-z0-9]{8,64}", serial):
        result["serialSuffix"] = serial[-4:]
    return result


async def deregister_device(auth, confirmed, timeout):
    if confirmed is not True:
        raise OperationError("deviceDeregistrationConfirmation")
    missing = not auth.access_token or auth.expires is None
    if missing or auth.access_token_expired:
        if device_registration(auth)["kind"] == "android":
            await refresh_android_access_token(auth, timeout)
        else:
            await auth.async_refresh_access_token(force=missing)
    if not auth.access_token:
        raise OperationError("authorization")

    host = "audible" if auth.with_username else "amazon"
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as web:
        response = await web.post(
            f"https://api.{host}.{auth.locale.domain}/auth/deregister",
            json={"deregister_all_existing_accounts": False},
            headers=build_access_token_header(auth.access_token),
        )
    response.raise_for_status()
    if response.status_code not in (200, 204):
        raise OperationError("deviceDeregistration")
    if response.content:
        try:
            data = response.json()
            envelope = data.get("response", data)
            if not isinstance(envelope, dict) or any(
                value.get("error") or value.get("error_code") or value.get("success") is False
                for value in (data, envelope)
            ):
                raise ValueError("Unexpected deregistration response")
        except (AttributeError, TypeError, ValueError) as error:
            raise OperationError("deviceDeregistration") from error
    return True


def duration_milliseconds(value):
    if type(value) not in (int, float, str) or (
        isinstance(value, str) and len(value) > 48
    ):
        raise OperationError("listeningStatsResponse")
    try:
        # Audible also returns millisecond counts as scientific notation or numeric strings.
        amount = Decimal(str(value))
        if (
            not amount.is_finite()
            or not 0 <= amount <= MAX_DURATION_MS
            or amount % 1 != 0
        ):
            raise ValueError("Invalid listening duration")
        return int(amount)
    except (InvalidOperation, ValueError) as error:
        raise OperationError("listeningStatsResponse") from error


async def listening_stats(client, start_year):
    today = datetime.now()
    if type(start_year) is not int or not 1997 <= start_year <= today.year:
        raise OperationError("listeningStatsYear")
    months = {}
    for year in range(start_year, today.year + 1):
        count = today.month if year == today.year else 12
        response = await client.get(
            "stats/aggregates",
            monthly_listening_interval_duration=str(count),
            monthly_listening_interval_start_date=f"{year}-01",
            store="Audible",
        )
        stats = (
            response.get("aggregated_monthly_listening_stats", [])
            if isinstance(response, dict)
            else None
        )
        if not isinstance(stats, list):
            raise OperationError("listeningStatsResponse")
        for row in stats:
            if not isinstance(row, dict):
                raise OperationError("listeningStatsResponse")
            month = row.get("interval_identifier")
            duration = duration_milliseconds(row.get("aggregated_sum"))
            if (
                not isinstance(month, str)
                or not MONTH.fullmatch(month)
                or not month.startswith(f"{year}-")
                or int(month[-2:]) > count
                or (month in months and months[month] != duration)
            ):
                raise OperationError("listeningStatsResponse")
            months[month] = duration
    return {
        "months": [
            {"month": month, "durationMilliseconds": duration}
            for month, duration in sorted(months.items())
        ]
    }


def offer(format_name, status, reason=None):
    data = {"format": format_name, "status": status}
    if reason is not None:
        data["reason"] = reason
    return data


def audio_metadata(codec, reference=None, chapter_info=None):
    fields = {}
    if isinstance(codec, str) and CODEC.fullmatch(codec):
        fields["codec"] = codec
        text = codec.lower()
        # Audible enhanced codecs include LC_64_22050_stereo and aax_44100_128.
        # The MIME codec identifier mp4a.40.2 does not encode a bitrate.
        rates = re.fullmatch(r"(?:lc|he)_(\d{1,4})_\d{4,6}(?:_(?:stereo|mono))?", text)
        if not rates:
            rates = re.fullmatch(r"aax_\d{2,6}_(\d{1,4})", text)
        if rates and 0 < int(rates[1]) <= 1024:
            fields["bitrateKbps"] = int(rates[1])
        if text.endswith("_stereo"):
            fields["channels"] = 2
        elif text.endswith("_mono"):
            fields["channels"] = 1
    if (
        "bitrateKbps" not in fields
        and isinstance(reference, dict)
        and isinstance(chapter_info, dict)
    ):
        size = reference.get("content_size_in_bytes")
        length = chapter_info.get("runtime_length_ms")
        if type(size) is int and size > 0 and type(length) is int and length > 0:
            kbps = (size * 8 + length // 2) // length
            if 0 < kbps <= 1024:
                fields["bitrateKbps"] = kbps
                fields["bitrateEstimated"] = True
    return fields


def license_metadata(content):
    metadata = content.get("content_metadata")
    if not isinstance(metadata, dict) or not isinstance(
        metadata.get("content_reference"), dict
    ):
        raise OperationError("licenseResponse")
    reference = metadata["content_reference"]
    codec = reference.get("codec") or reference.get("content_format")
    return audio_metadata(codec, reference, metadata.get("chapter_info"))


def aax_offer(item, quality):
    if item.is_ayce:
        return offer("aax", "notOffered", "aaxUnavailable")
    # Choose the same advertised AAX codec as a download without opening its URL.
    base_codec, enhanced = item._get_codec(quality)
    if not base_codec:
        return offer("aax", "notOffered", "aaxUnavailable")
    fields = audio_metadata(base_codec) | audio_metadata(enhanced)
    if (item.customer_rights or {}).get("is_consumable_offline") is not True:
        return offer("aax", "notChecked", "licenseEntitlement") | fields
    return offer("aax", "available") | fields


def describe_error(format_name, error, failure_code):
    code = failure_code(error)
    if code in ("aaxUnavailable", "aaxcUnavailable", "widevineUnavailable", "notFound"):
        return offer(format_name, "notOffered", code)
    if code in (
        "licenseDenied",
        "licenseEntitlement",
        "licenseThrottled",
        "requestRejected",
    ):
        return offer(format_name, "denied", code)
    if isinstance(error, (KeyError, TypeError, ValueError)):
        code = "licenseResponse"
    return offer(format_name, "error", code)


def check_aax(item, quality, failure_code):
    try:
        return aax_offer(item, quality)
    except (TypeError, KeyError, ValueError) as error:
        return describe_error("aax", error, failure_code)


async def check_aaxc(item, quality, failure_code):
    try:
        result = await item.get_license(quality, "content_reference,chapter_info")
        return offer("aaxc", "available") | license_metadata(result["content_license"])
    except OFFER_ERRORS as error:
        return describe_error("aaxc", error, failure_code)


async def check_widevine(item, auth, quality, timeout, check_license, failure_code):
    from widevine_download import WidevineLicenseClient, WidevineUnavailable

    try:
        client = WidevineLicenseClient(auth, timeout)
        metadata = await client.license(item.asin, quality, check_license)
        return offer("widevine", "available") | license_metadata(metadata)
    except WidevineUnavailable:
        return offer("widevine", "notOffered", "widevineUnavailable")
    except OFFER_ERRORS as error:
        if isinstance(error, OperationError) and error.code == "widevineRegistration":
            return offer("widevine", "notChecked", error.code)
        return describe_error("widevine", error, failure_code)


async def audio_offers(
    item, auth, quality, widevine_enabled, timeout, check_license, failure_code,
    *, preferred_format=None,
):
    book = {"asin": item.asin}
    rights = item.customer_rights or {}
    reason = (
        "podcastSeries"
        if item.is_parent_podcast()
        else "notPublished"
        if not item.is_published()
        else "offlineRestricted"
        if rights.get("is_consumable_offline") is False
        else None
    )
    if reason:
        return book | {"offers": [offer(fmt, "notChecked", reason) for fmt in FORMATS]}

    widevine = None
    if widevine_enabled and preferred_format in (None, "preferAAX"):
        widevine = await check_widevine(
            item, auth, quality, timeout, check_license, failure_code
        )
    if preferred_format is not None:
        offers = []
        if widevine is not None:
            offers.append(widevine)
            # The downloader falls back only when Audible explicitly has no Widevine offer.
            if widevine.get("reason") != "widevineUnavailable":
                return book | {"offers": offers}
        if preferred_format != "aaxcOnly":
            aax = check_aax(item, quality, failure_code)
            offers.append(aax)
            if preferred_format == "aaxOnly" or aax["status"] != "notOffered":
                return book | {"offers": offers}
        if rights.get("is_consumable_offline") is True:
            offers.append(await check_aaxc(item, quality, failure_code))
        else:
            offers.append(offer("aaxc", "notChecked", "licenseEntitlement"))
        return book | {"offers": offers}

    aax = check_aax(item, quality, failure_code)
    if widevine is None:
        widevine = offer("widevine", "notChecked", "widevineDisabled")
    stop = widevine.get("reason")
    if stop in PAUSE_CODES:
        aaxc = offer("aaxc", "notChecked", stop)
    else:
        aaxc = await check_aaxc(item, quality, failure_code)
    return book | {"offers": [aax, aaxc, widevine]}

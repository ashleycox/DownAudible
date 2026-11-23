"""Read a user-selected OpenAudible account file into memory."""

import asyncio
import hashlib
import json
import math
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import audible
import httpx
from android_sign_in import ANDROID_DEVICE_TYPE, refresh_android_access_token
from audible.auth import build_access_token_header
from audible.exceptions import RequestError, StatusError
from audible_cli.constants import AVAILABLE_MARKETPLACES
from download_transfer import OperationError

MAX_FILE_SIZE = 1024 * 1024
LEGACY_MARKETPLACES = {"de", "uk", "us"}


@dataclass(frozen=True)
class Profile:
    name: str
    marketplace: str
    is_default: bool
    checkpoint: str
    credentials: dict = field(repr=False)

    def listing(self):
        return {
            "name": self.name,
            "marketplace": self.marketplace,
            "isDefault": self.is_default,
            "checkpoint": self.checkpoint,
        }


def _unique_fields(pairs):
    fields = dict(pairs)
    if len(fields) != len(pairs):
        raise ValueError("Ambiguous account file")
    return fields


def _required_text(fields, name):
    value = fields[name]
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Missing registration field")
    return value


def _expiry(value):
    if value is None:
        return None
    if isinstance(value, str):
        value = float(value)
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError("Invalid token expiry")
    # OpenAudible stores epoch milliseconds. Older files may store seconds.
    expires = value / 1000 if value >= 1e11 else value
    datetime.fromtimestamp(expires, UTC)
    return expires


def _profile(name, record, active):
    label = " ".join(name.split())
    if not label or len(label) > 128 or not label.isprintable():
        raise ValueError("Invalid account name")
    marketplace = _required_text(record, "region").strip().lower()
    if marketplace == "gb":
        marketplace = "uk"
    if marketplace not in AVAILABLE_MARKETPLACES:
        raise ValueError("Unsupported marketplace")
    registration = record["details"]["response"]["success"]
    tokens = registration["tokens"]
    signing = tokens["mac_dms"]
    bearer = tokens["bearer"]
    extensions = registration["extensions"]
    device = extensions["device_info"]
    if not isinstance(device, dict) or not _required_text(device, "device_type"):
        raise ValueError("Invalid device registration")
    customer = extensions.get("customer_info")
    if customer is not None and not isinstance(customer, dict):
        raise ValueError("Invalid customer profile")

    website_cookies = {}
    cookies = tokens.get("website_cookies")
    if isinstance(cookies, list):
        for cookie in cookies:
            if isinstance(cookie, dict):
                key = cookie.get("Name")
                value = cookie.get("Value")
                if isinstance(key, str) and key and isinstance(value, str):
                    website_cookies[key] = value.replace('"', "")

    legacy = record.get("with_username") is True
    if legacy and marketplace not in LEGACY_MARKETPLACES:
        raise ValueError("Unsupported legacy marketplace")
    values = {
        "adp_token": _required_text(signing, "adp_token"),
        "device_private_key": _required_text(signing, "device_private_key"),
        "refresh_token": _required_text(bearer, "refresh_token"),
        "access_token": bearer.get("access_token"),
        "expires": _expiry(record.get("expires")),
        "website_cookies": website_cookies or None,
        "store_authentication_cookie": tokens.get("store_authentication_cookie"),
        "device_info": device,
        "customer_info": customer,
        "with_username": legacy,
        "locale_code": marketplace,
    }
    if values["access_token"] is not None:
        _required_text(values, "access_token")
    audible.Authenticator.from_dict(values.copy())
    canonical = json.dumps([name, record], sort_keys=True, allow_nan=False, separators=(",", ":"))
    checkpoint = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return Profile(label, marketplace, name == active, checkpoint, values)


def _read_profiles(file):
    try:
        path = Path(file)
        if not path.is_file():
            raise ValueError("Expected a regular file")
        with path.open("rb") as source:
            content = source.read(MAX_FILE_SIZE + 1)
        if not 0 < len(content) <= MAX_FILE_SIZE:
            raise ValueError("Account file size is out of range")
        records = json.loads(content, object_pairs_hook=_unique_fields)
        if not isinstance(records, dict):
            raise TypeError("Expected an account map")
    except (OSError, RecursionError, TypeError, ValueError) as error:
        raise OperationError("openAudibleFile") from error

    active = records.get("active_device")
    profiles = []
    for name, record in records.items():
        if name == "active_device" or not isinstance(record, dict):
            continue
        try:
            profiles.append(_profile(name, record, active))
        except (AttributeError, IndexError, KeyError, OSError, OverflowError, TypeError, ValueError):
            continue
    if not profiles:
        raise OperationError("openAudibleFile")
    return sorted(profiles, key=lambda profile: (not profile.is_default, profile.name.casefold(), profile.marketplace))


def inspect_open_audible(file):
    return [profile.listing() for profile in _read_profiles(file)]


def _customer_id(info):
    identifier = info.get("user_id") if isinstance(info, dict) else None
    return identifier if isinstance(identifier, str) and identifier.strip() else None


async def _verify_registration(auth, timeout):
    if not auth.access_token or auth.expires is None or auth.access_token_expired:
        if auth.device_info["device_type"] == ANDROID_DEVICE_TYPE:
            await refresh_android_access_token(auth, timeout)
        else:
            await auth.async_refresh_access_token(force=True)

    host = "audible" if auth.with_username else "amazon"
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as web:
        response = await web.get(f"https://api.{host}.{auth.locale.domain}/user/profile",
                                 headers=build_access_token_header(auth.access_token))
        response.raise_for_status()
        identifier = _customer_id(response.json())
    if identifier is None:
        raise OperationError("openAudibleVerify")
    expected = _customer_id(auth.customer_info)
    if expected is not None and identifier != expected:
        raise OperationError("accountMismatch")

    # The signed library request also validates the selected device registration.
    async with audible.AsyncClient(auth, timeout=timeout, follow_redirects=False) as client:
        library = await client.get("library", page=1, num_results=1)
    if not isinstance(library, dict) or not isinstance(library.get("items"), list):
        raise OperationError("openAudibleVerify")
    auth.customer_info = {**(auth.customer_info or {}), "user_id": identifier}


async def import_open_audible(file, checkpoint, timeout):
    profiles = _read_profiles(file)
    profile = next((entry for entry in profiles if entry.checkpoint == checkpoint), None)
    if profile is None:
        raise OperationError("openAudibleChanged")
    timeout = min(timeout or 45, 45)
    try:
        auth = audible.Authenticator.from_dict(profile.credentials.copy())
        async with asyncio.timeout(timeout):
            await _verify_registration(auth, timeout)
    except OperationError:
        raise
    except (httpx.HTTPStatusError, StatusError) as error:
        status = error.response.status_code
        if status == 429 or status >= 500:
            raise
        raise OperationError("openAudibleVerify") from error
    except (TimeoutError, httpx.RequestError, RequestError):
        raise
    except Exception as error:
        raise OperationError("openAudibleVerify") from error
    return {"session": json.dumps(auth.to_dict(), separators=(",", ":")), "marketplace": profile.marketplace}

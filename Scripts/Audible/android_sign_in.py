"""Browser sign-in and first-party Android device registration."""

import base64
import gzip
import hashlib
import hmac
import json
import re
import secrets
from datetime import UTC, datetime, timedelta
from urllib.parse import urlencode

import httpx
from audible.login import create_code_verifier, create_s256_code_challenge
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

from download_transfer import OperationError

# Current Android registration profile in rmcrackan/AudibleApi.
# https://github.com/rmcrackan/AudibleApi/blob/51b1e0465cfe171795d0c2c3feb43fa6bd79f013/AudibleApi/Authorization/RegistrationOptions.cs
ANDROID_DEVICE_TYPE = "A10KISP2GWF0E4"
APP_NAME = "com.audible.application"
APP_VERSION = "2090263407"
DEVICE_MODEL = "sdk_gphone64_x86_64"
OS_VERSION = r"google\/raven\/raven:14\/UPB5.230623.003\/10615560:user\/release-keys"
SOFTWARE_VERSION = "130050002"
LANGUAGES = {
    "au": "en-AU",
    "br": "pt-BR",
    "ca": "en-CA",
    "de": "de-DE",
    "es": "es-ES",
    "fr": "fr-FR",
    "in": "en-IN",
    "it": "it-IT",
    "jp": "ja-JP",
    "uk": "en-GB",
}


def client_id(serial):
    return f"{serial}#{ANDROID_DEVICE_TYPE}".encode("ascii").hex()


def registration_context(locale, serial):
    offset = datetime.now().astimezone().strftime("%z")
    timezone = f"{offset[1:3]}:{offset[3:]}"
    if offset.startswith("-"):
        timezone = "-" + timezone
    details = {
        "ApplicationName": APP_NAME,
        "ApplicationVersion": APP_VERSION,
        "DeviceOSVersion": OS_VERSION,
        "DeviceName": rf"ranchu\/Google\/{DEVICE_MODEL}",
        "ScreenWidthPixels": "1080",
        "ScreenHeightPixels": "2400",
        "ThirdPartyDeviceId": serial,
        "FirstPartyDeviceId": serial,
        "DeviceLanguage": LANGUAGES.get(locale.country_code, "en-US"),
        "TimeZone": timezone,
        "Carrier": "T-Mobile",
        "IpAddress": "0.0.0.0",
    }
    payload = gzip.compress(json.dumps(details, separators=(",", ":")).encode("utf-8"))
    seed = serial.encode("ascii")
    iv = secrets.token_bytes(AES.block_size)
    enc_key = hashlib.pbkdf2_hmac("sha1", seed, b"AES/CBC/PKCS7Padding", 1000, 16)
    mac_key = hashlib.pbkdf2_hmac("sha1", seed, b"HmacSHA256", 1000, 16)
    encrypted = AES.new(enc_key, AES.MODE_CBC, iv).encrypt(pad(payload, AES.block_size))
    digest = hmac.digest(mac_key, iv + encrypted, "sha256")[:8]
    return base64.b64encode(b"\0" + digest + iv + encrypted).decode("ascii")


def begin_android_sign_in(locale):
    verifier = create_code_verifier()
    serial = secrets.token_hex(10)
    country, domain = locale.country_code, locale.domain
    select_id = "http://specs.openid.net/auth/2.0/identifier_select"
    params = {
        "openid.pape.max_auth_age": "0",
        "openid.identity": select_id,
        "accountStatusPolicy": "P1",
        "marketPlaceId": locale.market_place_id,
        "pageId": f"amzn_audible_android_aui_v2_dark_{country}",
        "openid.return_to": f"https://www.audible.{domain}/ap/maplanding",
        "openid.assoc_handle": f"amzn_audible_android_aui_{country}",
        "openid.oa2.response_type": "code",
        "openid.mode": "checkid_setup",
        "openid.ns.pape": "http://specs.openid.net/extensions/pape/1.0",
        "openid.oa2.code_challenge_method": "S256",
        "openid.ns.oa2": "http://www.amazon.com/ap/ext/oauth/2",
        "openid.oa2.code_challenge": create_s256_code_challenge(verifier).decode(
            "ascii"
        ),
        "openid.oa2.scope": "device_auth_access",
        "openid.claimed_id": select_id,
        "openid.oa2.client_id": f"device:{client_id(serial)}",
        "openid.ns": "http://specs.openid.net/auth/2.0",
        "disableLoginPrepopulate": "1",
    }
    return {
        "url": f"https://www.amazon.{domain}/ap/signin?{urlencode(params)}",
        "serial": serial,
        "verifier": verifier.decode("ascii"),
        "registrationContext": registration_context(locale, serial),
    }


def registration_credentials(response):
    success = response["response"]["success"]
    tokens = success["tokens"]
    extensions = success["extensions"]
    bearer = tokens["bearer"]
    signing = tokens["mac_dms"]
    device = extensions["device_info"]
    customer = extensions["customer_info"]
    user_id = customer.get("user_id")
    if (
        device["device_type"] != ANDROID_DEVICE_TYPE
        or not isinstance(user_id, str)
        or not user_id.strip()
    ):
        raise OperationError("signInFailed")

    website_cookies = {
        cookie["Name"]: cookie["Value"].replace(r"\"", '"')
        for cookie in tokens.get("website_cookies") or ()
    }
    seconds = int(bearer["expires_in"])
    if seconds <= 0:
        raise OperationError("signInFailed")
    sensitive = {
        "adp_token": signing["adp_token"],
        "device_private_key": signing["device_private_key"],
        "refresh_token": bearer["refresh_token"],
        "access_token": bearer["access_token"],
    }
    if not all(isinstance(value, str) and value for value in sensitive.values()):
        raise OperationError("signInFailed")
    return {
        **sensitive,
        "expires": (datetime.now(UTC) + timedelta(seconds=seconds)).timestamp(),
        "website_cookies": website_cookies or None,
        "store_authentication_cookie": tokens.get("store_authentication_cookie"),
        "device_info": device,
        "customer_info": customer,
    }


def register_android(locale, authorization_code, verifier, serial, context, timeout):
    if (
        not isinstance(serial, str)
        or not re.fullmatch(r"[a-f0-9]{20}", serial)
        or not isinstance(verifier, str)
        or not re.fullmatch(r"[A-Za-z0-9_~-]{43}", verifier)
        or not isinstance(context, str)
        or not 128 <= len(context) <= 2048
        or not re.fullmatch(r"[A-Za-z0-9+/]+=*", context)
    ):
        raise OperationError("signInFailed")
    domain = locale.domain
    body = {
        "requested_token_type": [
            "bearer",
            "mac_dms",
            "store_authentication_cookie",
            "website_cookies",
        ],
        "cookies": {"domain": f"www.amazon.{domain}", "website_cookies": []},
        "user_context_map": {"frc": context},
        "registration_data": {
            "domain": "DeviceLegacy",
            "device_type": ANDROID_DEVICE_TYPE,
            "device_serial": serial,
            "app_name": APP_NAME,
            "app_version": APP_VERSION,
            "device_model": DEVICE_MODEL,
            "os_version": OS_VERSION,
            "software_version": SOFTWARE_VERSION,
            "device_name": "Audible for Android",
        },
        "auth_data": {
            "authorization_code": authorization_code,
            "code_verifier": verifier,
            "code_algorithm": "SHA-256",
            "client_domain": "DeviceLegacy",
            "client_id": client_id(serial),
            "use_global_authentication": "true",
        },
        "requested_extensions": ["device_info", "customer_info"],
        "device_metadata": {
            "device_os_family": "android",
            "device_type": ANDROID_DEVICE_TYPE,
            "device_serial": serial,
            "manufacturer": "Google",
            "model": DEVICE_MODEL,
            "os_version": "34",
            "product": DEVICE_MODEL,
        },
    }
    response = httpx.post(
        f"https://api.amazon.{domain}/auth/register",
        json=body,
        timeout=timeout,
        follow_redirects=False,
    )
    response.raise_for_status()
    return registration_credentials(response.json())


async def refresh_android_access_token(auth, timeout):
    host = "audible" if auth.with_username else "amazon"
    origin = f"api.{host}.{auth.locale.domain}"
    body = {
        "app_name": APP_NAME,
        "app_version": APP_VERSION,
        "source_token": auth.refresh_token,
        "requested_token_type": "access_token",
        "source_token_type": "refresh_token",
    }
    if not auth.refresh_token:
        raise OperationError("widevineRegistration")
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as web:
        response = await web.post(
            f"https://{origin}/auth/token",
            data=body,
            headers={"x-amzn-identity-auth-domain": origin},
        )
    response.raise_for_status()
    try:
        result = response.json()
        expires = int(result["expires_in"])
        if expires <= 0:
            raise ValueError("Invalid access token lifetime")
        expiry = (datetime.now(UTC) + timedelta(seconds=expires)).timestamp()
        token = result["access_token"]
        if not isinstance(token, str) or not token:
            raise ValueError("Missing access token")
        auth.access_token = token
        auth.expires = expiry
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise OperationError("widevineRegistration") from error

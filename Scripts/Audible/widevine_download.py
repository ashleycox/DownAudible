"""Opt-in Audible Widevine stereo downloads with an account-linked Android CDM."""

import asyncio
import base64
import contextlib
import re
import secrets
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID
from xml.etree import ElementTree as ET

import httpx
from audible.utils import build_access_token_header
from audible_cli.models import api_quality
from google.protobuf.message import DecodeError
from pywidevine.cdm import Cdm
from pywidevine.device import Device, DeviceTypes
from pywidevine.pssh import PSSH

from android_sign_in import ANDROID_DEVICE_TYPE, refresh_android_access_token
from download_transfer import (
    OperationError,
    artifact_response,
    check_staging_path,
    fingerprint,
    stream_file,
)

PROVISIONER = "https://ollj0gz40d.execute-api.us-west-2.amazonaws.com/default/AudibleCdm"
STEREO_CODECS = ("mp4a.40.2", "mp4a.40.42")
DASH = "urn:mpeg:dash:schema:mpd:2011"
CENC = "urn:mpeg:cenc:2013"
NS = {"dash": DASH, "cenc": CENC}
MAX_CDM_BYTES = 64 * 1024
MAX_METADATA_BYTES = 1024 * 1024


class WidevineUnavailable(Exception):
    """Audible explicitly offered no usable Widevine stereo format."""


@dataclass(frozen=True)
class Manifest:
    url: httpx.URL
    pssh: PSSH
    kid: UUID | None


def check_registration(auth):
    info = auth.device_info
    has_bearer = auth.refresh_token or (
        auth.access_token and auth.expires is not None and not auth.access_token_expired
    )
    if (
        not isinstance(info, dict)
        or info.get("device_type") != ANDROID_DEVICE_TYPE
        or not auth.adp_token
        or not auth.device_private_key
        or not has_bearer
    ):
        raise OperationError("widevineRegistration")


def android_device(data):
    if not isinstance(data, bytes) or not 0 < len(data) <= MAX_CDM_BYTES:
        raise ValueError("CDM size")
    device = Device.loads(data)
    if device.type != DeviceTypes.ANDROID or device.security_level != 3:
        raise ValueError("CDM type")
    return device


async def bounded_body(response, limit, error):
    response.raise_for_status()
    data = bytearray()
    async for block in response.aiter_bytes(16 * 1024):
        if len(data) + len(block) > limit:
            raise OperationError(error)
        data.extend(block)
    return bytes(data)


async def provision(auth, consent, timeout):
    if consent is not True:
        raise OperationError("widevineConsent")
    check_registration(auth)
    target = httpx.Request(
        "GET", f"https://api.audible.{auth.locale.domain}/1.0/account/information"
    )
    try:
        auth.sign_request(target)
        signed = {
            key: target.headers[key]
            for key in ("x-adp-token", "x-adp-alg", "x-adp-signature")
        }
    except (KeyError, TypeError, ValueError) as error:
        raise OperationError("widevineRegistration") from error
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as web:
            async with web.stream(
                "POST", PROVISIONER, json={"Url": str(target.url), "Headers": signed}
            ) as response:
                cdm = await bounded_body(response, MAX_CDM_BYTES, "widevineProvision")
        android_device(cdm)
    except Exception as error:
        # Device parsing crosses several serialization libraries and may expose input.
        raise OperationError("widevineProvision") from error
    return {"cdm": base64.b64encode(cdm).decode("ascii")}


def parse_manifest(data, url):
    try:
        # DASH is well formed UTF-8 and needs no document type or entity declarations.
        xml = data.decode("utf-8-sig")
        if "<!DOCTYPE" in xml or "<!ENTITY" in xml:
            raise ValueError("DASH document type")
        document = ET.fromstring(xml)
        if document.tag != f"{{{DASH}}}MPD" or document.get("type") == "dynamic":
            raise ValueError("DASH type")
        periods = document.findall("dash:Period", NS)
        if len(periods) != 1:
            raise ValueError("DASH periods")
        if any(
            document.find(f".//dash:{tag}", NS) is not None
            for tag in ("SegmentTemplate", "SegmentList")
        ):
            raise ValueError("DASH segments")
        sources = {
            element.text.strip()
            for element in document.findall(".//dash:BaseURL", NS)
            if element.text and element.text.strip()
        }
        protection = document.findall(".//dash:ContentProtection", NS)
        headers = {
            element.text.strip()
            for entry in protection
            if entry.get("schemeIdUri", "").casefold() == Cdm.urn
            for element in entry.findall("cenc:pssh", NS)
            if element.text and element.text.strip()
        }
        ids = {
            UUID(entry.attrib[f"{{{CENC}}}default_KID"])
            for entry in protection
            if f"{{{CENC}}}default_KID" in entry.attrib
        }
        if len(sources) != 1 or len(headers) != 1 or len(ids) > 1:
            raise ValueError("DASH representation")
        source = secure_url(url.join(sources.pop()))
        pssh = PSSH(base64.b64decode(headers.pop(), validate=True), strict=True)
        if pssh.system_id != PSSH.SystemId.Widevine:
            raise ValueError("DASH protection system")
        kid = next(iter(ids), None)
        if kid is None and len(pssh.key_ids) == 1:
            kid = pssh.key_ids[0]
        return Manifest(source, pssh, kid)
    except (ET.ParseError, UnicodeError, ValueError, TypeError, AttributeError, DecodeError) as error:
        raise OperationError("widevineManifest") from error


def secure_url(value):
    url = httpx.URL(value)
    if (
        url.scheme != "https"
        or not url.host
        or url.port not in (None, 443)
        or url.username
        or url.password
    ):
        raise ValueError("Widevine URL")
    return url


async def content_manifest(web, location):
    try:
        url = secure_url(location)
        async with artifact_response(web, url, None, {}) as response:
            data = await bounded_body(response, MAX_METADATA_BYTES, "widevineManifest")
            return parse_manifest(data, response.url)
    except (ValueError, httpx.InvalidURL) as error:
        raise OperationError("widevineManifest") from error


def chapter_metadata(chapters):
    text = [";FFMETADATA1"]
    for chapter in chapters:
        title = chapter["title"].replace("\0", "").replace("\r", " ").replace("\n", " ")
        title = re.sub(r"([\\=;#])", r"\\\1", title)
        start = chapter["startMilliseconds"]
        end = start + chapter["durationMilliseconds"]
        text.extend(
            ("[CHAPTER]", "TIMEBASE=1/1000", f"START={start}", f"END={end}", f"title={title}")
        )
    return "\n".join(text) + "\n"


async def remux_audio(ffmpeg, encrypted, output, key, chapters):
    location = "file:" + encrypted.absolute().as_posix()
    if any(char in location for char in "\r\n"):
        raise OperationError("stagingFileAccess")
    escaped = location.replace("'", "'\\''")
    # The licensed key reaches the MOV demuxer via a private stdin pipe.
    script = f"ffconcat version 1.0\nfile '{escaped}'\noption decryption_key {key.hex()}\n"
    check_staging_path(output)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        scratch = Path(temporary)
        arguments = [
            "-nostdin", "-loglevel", "quiet", "-xerror", "-protocol_whitelist",
            "pipe,file", "-f", "concat", "-safe", "0", "-i", "pipe:0",
        ]
        if chapters:
            metadata = scratch / "chapters.ffmetadata"
            metadata.write_text(chapter_metadata(chapters), encoding="utf-8")
            arguments += ["-f", "ffmetadata", "-i", str(metadata), "-map_chapters", "1"]
        staged = scratch / "audio.m4b"
        flags = {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}
        try:
            process = await asyncio.create_subprocess_exec(
                str(ffmpeg), *arguments,
                "-map", "0:a:0", "-c:a", "copy", "-f", "mp4", str(staged),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
                **flags,
            )
        except FileNotFoundError as error:
            raise OperationError("widevineAudio") from error
        try:
            await process.communicate(script.encode("utf-8"))
        except asyncio.CancelledError:
            if process.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    process.kill()
            await process.wait()
            raise
        if process.returncode or not staged.is_file() or staged.stat().st_size == 0:
            raise OperationError("widevineAudio")
        staged.replace(output)


class WidevineLicenseClient:
    def __init__(self, auth, timeout):
        check_registration(auth)
        self.auth = auth
        self.timeout = timeout

    async def audible_post(self, route, body):
        missing_token = not self.auth.access_token or self.auth.expires is None
        if missing_token or self.auth.access_token_expired:
            await refresh_android_access_token(self.auth, self.timeout)
        if not self.auth.access_token:
            raise OperationError("widevineRegistration")
        async with httpx.AsyncClient(timeout=self.timeout, follow_redirects=False) as web:
            request = web.build_request(
                "POST",
                f"https://api.audible.{self.auth.locale.domain}/1.0/{route}",
                json=body,
                headers={
                    **build_access_token_header(self.auth.access_token),
                    "x-amzn-identity-auth-domain": f"www.audible.{self.auth.locale.domain}",
                    "X-Amzn-RequestId": secrets.token_hex(20).upper(),
                },
            )
            self.auth.sign_request(request)
            return await web.send(request)

    async def license(self, asin, quality, check_license):
        response = await self.audible_post(
            f"content/{asin}/licenserequest",
            {
                "supported_media_features": {
                    "drm_types": ["Widevine", "Mpeg"],
                    "codecs": list(STEREO_CODECS),
                    "chapter_titles_type": "Flat",
                    "previews": False,
                    "catalog_samples": False,
                },
                "spatial": False,
                "consumption_type": "Download",
                "tenant_id": "Audible",
                "quality": api_quality(quality),
                "response_groups": "content_reference,chapter_info",
            },
        )
        try:
            grant = check_license(response)["content_license"]
        except OperationError as error:
            if error.code == "aaxcUnavailable":
                raise WidevineUnavailable() from error
            raise
        if grant.get("status_code") != "Granted":
            raise OperationError("widevineLicense")
        if grant.get("drm_type") in ("Mpeg", "Adrm"):
            raise WidevineUnavailable()
        try:
            codec = grant["content_metadata"]["content_reference"]["codec"]
            if grant["drm_type"] != "Widevine" or not isinstance(grant["license_response"], str):
                raise ValueError("Widevine license")
        except (TypeError, KeyError, ValueError) as error:
            raise OperationError("widevineLicense") from error
        if not isinstance(codec, str):
            raise OperationError("widevineLicense")
        if codec.casefold() not in STEREO_CODECS:
            raise WidevineUnavailable()
        return grant


class WidevineDownload(WidevineLicenseClient):
    def __init__(self, auth, encoded_device, ffmpeg, timeout):
        super().__init__(auth, timeout)
        if (
            not isinstance(encoded_device, str)
            or len(encoded_device) > 4 * ((MAX_CDM_BYTES + 2) // 3)
        ):
            raise OperationError("widevineProvision")
        try:
            self.device = android_device(base64.b64decode(encoded_device, validate=True))
        except Exception as error:
            raise OperationError("widevineProvision") from error
        self.ffmpeg = Path(ffmpeg) if isinstance(ffmpeg, str) else None
        if self.ffmpeg is None or not self.ffmpeg.is_absolute() or not self.ffmpeg.is_file():
            raise OperationError("widevineAudio")

    async def content_key(self, asin, manifest):
        cdm = Cdm.from_device(self.device)
        session = cdm.open()
        try:
            challenge = cdm.get_license_challenge(
                session, manifest.pssh, license_type="OFFLINE", privacy_mode=False
            )
            response = await self.audible_post(
                f"content/{asin}/drmlicense",
                {
                    "consumption_type": "Download",
                    "drm_type": "Widevine",
                    "tenant_id": "Audible",
                    "licenseChallenge": base64.b64encode(challenge).decode("ascii"),
                },
            )
            response.raise_for_status()
            cdm.parse_license(session, response.json()["license"])
            keys = [
                key.key
                for key in cdm.get_keys(session, "CONTENT")
                if len(key.key) == 16 and (manifest.kid is None or key.kid == manifest.kid)
            ]
            if len(keys) != 1:
                raise ValueError("Widevine content key")
            return keys[0]
        except (OSError, httpx.HTTPError):
            raise
        except Exception as error:
            raise OperationError("widevineLicense") from error
        finally:
            cdm.close(session)

    async def download(
        self, asin, web, folder, quality, bandwidth, progress, check_license, extract_chapters
    ):
        grant = await self.license(asin, quality, check_license)
        manifest = await content_manifest(web, grant["license_response"])
        key = await self.content_key(asin, manifest)
        encrypted = folder / f"{asin}.widevine.m4a"
        target = await stream_file(
            web, manifest.url, encrypted, "mp4",
            lambda amount: progress(amount * 0.99) if progress else None,
            bandwidth=bandwidth,
            representation=fingerprint(
                "widevine", quality, manifest.pssh.dumps(), str(manifest.kid)
            ),
        )
        output = folder / f"{asin}.m4b"
        await remux_audio(
            self.ffmpeg, target.path, output, key, extract_chapters(grant)
        )
        target.path.unlink(missing_ok=True)
        encrypted.with_name(encrypted.name + ".transfer.json").unlink(missing_ok=True)
        if progress:
            progress(1.0)
        return {
            "file": output.name,
            "asin": asin,
            "credentials": {},
            "downloadedBytes": target.transferred_bytes,
        }

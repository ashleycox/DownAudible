"""Staged audio transfers and validated HTTP byte ranges."""

import asyncio
import contextlib
import hashlib
import json
import re
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from unicodedata import category
from urllib.parse import unquote

import httpx
from audible_cli.constants import AAX_CONTENT_TYPES, AAXC_CONTENT_TYPES

CHUNK_SIZE = 256 * 1024
HTTP_TOKEN = r"[!#$%&'*+.\-^_`|~0-9A-Za-z]+"
DISPOSITION_PARAMETER = re.compile(
    rf"[ \t]*;[ \t]*({HTTP_TOKEN})[ \t]*=[ \t]*"
    rf'(?:"((?:[^"\\\r\n]|\\[^\r\n])*)"|({HTTP_TOKEN}))'
)
EXTENDED_FILENAME = re.compile(
    r"([a-zA-Z0-9_-]+)'[a-zA-Z0-9-]*'((?:[!#$&+.\-^_`|~a-zA-Z0-9]|%[0-9a-fA-F]{2})+)"
)


class OperationError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class PartsRequired(Exception):
    pass


class FormatUnavailable(OperationError):
    def __init__(self, code="downloadResponse", *, status_code=None):
        super().__init__(code)
        self.status_code = status_code


class RestartDownload(Exception):
    pass


def fingerprint(*values):
    payload = json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


@dataclass(frozen=True)
class DownloadedFile:
    path: Path
    original_filename: str | None = None


@dataclass(frozen=True)
class TransferState:
    representation: str
    resource: str
    etag: str | None
    length: int | None
    original_filename: str | None = None

    @classmethod
    def load(cls, path, representation):
        try:
            data = json.loads(path.read_text())
            if data.pop("version", None) != 1:
                return None
            state = cls(**data)
            if state.representation == representation:
                return state
        except (FileNotFoundError, UnicodeError, ValueError, TypeError, AttributeError):
            pass
        return None

    def save(self, path):
        temporary = path.with_name(path.name + ".tmp")
        check_staging_path(temporary)
        try:
            temporary.write_text(json.dumps({"version": 1, **asdict(self)}))
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def check_staging_path(path):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise OperationError("stagingFileAccess")


def artifact_matches(prefix, content_type, kind):
    if kind in ("aax", "aaxc"):
        expected = AAX_CONTENT_TYPES if kind == "aax" else AAXC_CONTENT_TYPES
        return (
            content_type in (*expected, "application/octet-stream")
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
async def artifact_response(web, url, api, headers):
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
        # Keep account signing headers on Audible's hosts when a response redirects to a CDN.
        async with client.stream(
            "GET", url, headers=headers, follow_redirects=False
        ) as response:
            if response.has_redirect_location:
                url = response.url.join(response.headers["location"])
            else:
                yield response
                return
    raise FormatUnavailable()


def resource_hash(response):
    return fingerprint(str(response.url.copy_with(query=None, fragment=None)))


def is_aax_filename(value):
    return (
        isinstance(value, str)
        and value.lower().endswith(".aax")
        and not value.startswith(".")
        and bool(value[:-4].strip())
        and not any(
            char in "/:\\" or category(char) in ("Cc", "Cf", "Cs") for char in value
        )
        and len(value.encode("utf-8")) <= 255
    )


def disposition_filename(header):
    header = header.strip(" \t")
    disposition, _, _ = header.partition(";")
    if not re.fullmatch(HTTP_TOKEN, disposition.strip(" \t")):
        return None
    parameters = {}
    start = len(disposition)
    while start < len(header):
        parameter = DISPOSITION_PARAMETER.match(header, start)
        if parameter is None:
            return None
        key, quoted, token = parameter.groups()
        key = key.lower()
        if key in parameters:
            return None
        parameters[key] = token if quoted is None else re.sub(r'\\(["\\])', r"\1", quoted)
        start = parameter.end()

    # Prefer the encoded name when the response supplies an ASCII fallback as well.
    extended = EXTENDED_FILENAME.fullmatch(parameters.get("filename*", ""))
    if extended:
        charset, encoded = extended.groups()
        if charset.lower() in ("utf-8", "iso-8859-1"):
            try:
                name = unquote(encoded, encoding=charset, errors="strict")
            except UnicodeError:
                pass
            else:
                if is_aax_filename(name):
                    return name
    name = parameters.get("filename")
    return name if is_aax_filename(name) else None


def aax_filename(response):
    name = disposition_filename(response.headers.get("content-disposition", ""))
    if name is not None:
        return name
    raw = response.url.raw_path.partition(b"?")[0].rsplit(b"/", 1)[-1]
    if re.search(rb"%(?![0-9a-fA-F]{2})", raw):
        return None
    try:
        name = unquote(raw, errors="strict")
    except UnicodeError:
        return None
    return name if is_aax_filename(name) else None


def strong_etag(value):
    return (
        value
        if isinstance(value, str) and re.fullmatch(r'"[!#-~\x80-\xff]*"', value)
        else None
    )


def identity_length(response):
    if response.headers.get("content-encoding", "identity").lower() != "identity":
        return None
    value = response.headers.get("content-length", "")
    return int(value) if value.isdecimal() else None


def append_range(response, state, offset):
    if (
        response.headers.get("content-encoding", "identity").lower() != "identity"
        or strong_etag(response.headers.get("etag")) != state.etag
        or resource_hash(response) != state.resource
    ):
        raise RestartDownload()
    content_range = response.headers.get("content-range", "")
    if response.status_code == 416:
        if content_range == f"bytes */{state.length}" and state.length == offset:
            return state.length
        raise RestartDownload()
    if response.status_code != 206:
        raise RestartDownload()
    match = re.fullmatch(r"bytes ([0-9]+)-([0-9]+)/([0-9]+)", content_range)
    if not match:
        raise RestartDownload()
    start, end, total = map(int, match.groups())
    length = identity_length(response)
    if (
        start != offset
        or total != state.length
        or end != total - 1
        or start > end
        or (length is not None and length != end - start + 1)
    ):
        raise RestartDownload()
    return total


async def write_body(output, iterator, first, offset, expected, progress, bandwidth):
    written = offset
    last_update = -1
    now = asyncio.get_running_loop().time
    started = now()
    data = first
    while data:
        if expected is not None and written + len(data) > expected:
            raise OperationError("incompleteResponse")
        # Unbuffered writes make the actual file length available after a cancelled process exits.
        if output.write(data) != len(data):
            raise OperationError("stagingFileAccess")
        written += len(data)
        if bandwidth:
            delay = started + (written - offset) / bandwidth - now()
            if delay > 0:
                await asyncio.sleep(delay)
        if progress and expected:
            percent = min(99, int(written * 100 / expected))
            if percent > last_update:
                progress(percent / 100)
                last_update = percent
        data = await anext(iterator, b"")
    if expected is not None and written != expected:
        raise OperationError("incompleteResponse")
    return written


async def receive(
    response, target, kind, progress, bandwidth, representation, state_path, resume
):
    if response.status_code in (400, 401, 403, 404, 410):
        raise FormatUnavailable("sourceRejected", status_code=response.status_code)
    filename = None
    if response.status_code in (206, 416):
        if resume is None:
            raise OperationError("incompleteResponse")
        state, offset = resume
        expected = append_range(response, state, offset)
        if kind == "aax":
            filename = (
                state.original_filename
                if is_aax_filename(state.original_filename)
                else aax_filename(response)
            )
        if progress:
            progress(min(0.99, offset / expected))
    else:
        response.raise_for_status()
        if response.status_code != 200 or response.headers.get("content-range"):
            raise OperationError("incompleteResponse")
        offset = 0
        expected = identity_length(response)
        if kind == "aax":
            filename = aax_filename(response)
        state = (
            TransferState(
                representation,
                resource_hash(response),
                strong_etag(response.headers.get("etag")),
                expected,
                filename,
            )
            if representation is not None
            else None
        )

    chunk_size = min(CHUNK_SIZE, max(4096, bandwidth // 4)) if bandwidth else CHUNK_SIZE
    # Identity encoding is required for retaking a durable byte offset.
    iterator = response.aiter_bytes(chunk_size=chunk_size)
    first = b"" if response.status_code == 416 else await anext(iterator, b"")
    if offset == 0:
        content_type = (
            response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        )
        if not artifact_matches(first, content_type, kind):
            if b"please download individual parts" in first.lower():
                raise PartsRequired()
            raise FormatUnavailable()
        if kind == "cover":
            target = target.with_suffix("." + image_extension(first))

    partial = target.with_name(target.name + ".partial")
    check_staging_path(target)
    check_staging_path(partial)
    if state is not None and offset == 0:
        # An earlier complete file must not be mistaken for the new representation.
        target.unlink(missing_ok=True)
    if kind == "aaxc" and representation is None:
        # A fresh license didn't include a key to identify this representation.
        check_staging_path(state_path)
        state_path.unlink(missing_ok=True)
    try:
        with partial.open("ab" if offset else "wb", buffering=0) as output:
            if offset and output.tell() != offset:
                raise OperationError("stagingFileAccess")
            if state is not None and offset == 0:
                state.save(state_path)
            written = await write_body(
                output,
                iterator,
                first,
                offset,
                expected,
                progress,
                bandwidth,
            )
        if state is not None:
            updated = replace(state, length=written, original_filename=filename)
            if updated != state:
                updated.save(state_path)
        partial.replace(target)
    finally:
        if kind not in ("aax", "aaxc", "mp3"):
            partial.unlink(missing_ok=True)
    return DownloadedFile(target, filename)


async def stream_file(
    web, url, target, kind, progress=None, *, api=None, bandwidth=0, representation=None
):
    resume = None
    state_path = target.with_name(target.name + ".transfer.json")
    if representation is not None:
        partial = target.with_name(target.name + ".partial")
        for path in (target, partial, state_path):
            check_staging_path(path)
        state = TransferState.load(state_path, representation)
        if state is not None and isinstance(state.length, int) and state.length > 0:
            if target.is_file() and target.stat().st_size == state.length:
                if progress:
                    progress(1.0)
                name = state.original_filename
                return DownloadedFile(
                    target, name if kind == "aax" and is_aax_filename(name) else None
                )
            if partial.is_file() and strong_etag(state.etag):
                offset = partial.stat().st_size
                if 0 < offset <= state.length:
                    resume = state, offset

    if resume is not None:
        state, offset = resume
        headers = {
            "Range": f"bytes={offset}-",
            "If-Range": state.etag,
            "Accept-Encoding": "identity",
        }
        try:
            async with artifact_response(web, url, api, headers) as response:
                result = await receive(
                    response,
                    target,
                    kind,
                    progress,
                    bandwidth,
                    representation,
                    state_path,
                    resume,
                )
        except RestartDownload:
            resume = None
    if resume is None:
        async with artifact_response(
            web, url, api, {"Accept-Encoding": "identity"}
        ) as response:
            result = await receive(
                response,
                target,
                kind,
                progress,
                bandwidth,
                representation,
                state_path,
                None,
            )
    if progress:
        progress(1.0)
    return result

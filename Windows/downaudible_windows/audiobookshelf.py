"""Audiobookshelf HTTP client and the persistent queue for saved audio."""

from collections.abc import Iterable
from contextlib import ExitStack, contextmanager
from dataclasses import asdict, dataclass
from hashlib import sha256
from http.client import HTTPConnection, HTTPException, HTTPSConnection
from ipaddress import ip_address
from json import JSONDecodeError, dumps, loads
from mimetypes import guess_type
from os import fstat
from pathlib import Path
from stat import S_ISREG
from threading import Condition, Event, Thread
from time import time
from urllib.parse import quote, urlencode, urlsplit, urlunsplit
from uuid import uuid4

from .archive import recorded_file, safe_filename
from .audible import AudibleError
from .state import read_json, write_json

AUDIO_SUFFIXES = {".m4a", ".m4b", ".mp3"}
COVER_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
VAULT_REFERENCE = "audiobookshelf-api-token"
HISTORY_LIMIT = 200
MAX_JSON = 16 * 1024 * 1024
TRANSFER_BLOCK = 256 * 1024
MATCH_LIMIT = 50


class ShelfError(ValueError):
    pass


def normalize_server(value):
    value = value.strip()
    if not value or any(ord(character) < 33 for character in value) or "\\" in value:
        raise ShelfError("Enter the Audiobookshelf server URL.")
    try:
        parsed = urlsplit(value)
        port, hostname = parsed.port, parsed.hostname
        if (parsed.scheme not in {"http", "https"} or not hostname or parsed.username is not None
                or parsed.password is not None or parsed.query or parsed.fragment
                or "?" in value or "#" in value):
            raise ValueError
        hostname = hostname.encode("idna").decode("ascii").lower()
    except (ValueError, UnicodeError):
        raise ShelfError("Use a server URL without a username, password, query, or fragment.") from None
    try:
        address = ip_address(hostname)
    except ValueError:
        address = None
    is_local = hostname.rstrip(".") == "localhost" or (
        address is not None and (address.is_private or address.is_loopback)
    )
    if parsed.scheme == "http" and not is_local:
        raise ShelfError("Use HTTPS for Audiobookshelf servers outside the local network.")
    host = f"[{hostname}]" if ":" in hostname else hostname
    if port is not None and port != (443 if parsed.scheme == "https" else 80):
        host += f":{port}"
    path = quote(parsed.path.rstrip("/"), safe="/%:@!$&'()*+,;=-._~")
    return urlunsplit((parsed.scheme, host, path, "", ""))


def server_origin(server):
    parsed = urlsplit(normalize_server(server))
    return f"{parsed.scheme}://{parsed.netloc}"


def validate_token(token):
    token = token.strip()
    if not token or len(token) > 8192 or not all(33 <= ord(character) <= 126 for character in token):
        raise ShelfError("Enter a valid Audiobookshelf API token.")
    return token


def stored_token(client, server):
    if not server or client.demo:
        return ""
    try:
        entry = loads(client.session(VAULT_REFERENCE))
        if isinstance(entry, dict) and entry.get("origin") == server_origin(server):
            return validate_token(entry.get("token", ""))
    except AudibleError as error:
        if error.code != "notSignedIn":
            raise ShelfError("DownAudible could not read the saved Audiobookshelf token.") from None
    except (ValueError, AttributeError, TypeError):
        raise ShelfError("DownAudible could not read the saved Audiobookshelf token.") from None
    return ""


@contextmanager
def update_token(client, server, token):
    record = dumps({"origin": server_origin(server), "token": validate_token(token)}) if token else None
    try:
        with client.session_change(VAULT_REFERENCE, record):
            yield
    except AudibleError:
        raise ShelfError("DownAudible could not save the Audiobookshelf token in your Windows profile.") from None


@dataclass(frozen=True)
class ShelfFolder:
    id: str
    path: str


@dataclass(frozen=True)
class ShelfLibrary:
    id: str
    name: str
    folders: tuple[ShelfFolder, ...]


@dataclass(frozen=True)
class UploadTarget:
    server: str
    library_id: str
    folder_id: str
    library_name: str = ""
    folder_name: str = ""

    @classmethod
    def from_settings(cls, settings):
        if not isinstance(settings, dict) or not all(isinstance(settings.get(key), str) and settings[key]
                                                       for key in ("server", "library_id", "folder_id")):
            return None
        return cls(normalize_server(settings["server"]), settings["library_id"], settings["folder_id"],
                   settings.get("library_name", ""), settings.get("folder_name", ""))

    @property
    def identity(self):
        return self.server, self.library_id, self.folder_id


@dataclass(frozen=True)
class UploadFile:
    path: str
    name: str
    size: int
    modified: int

    def __post_init__(self):
        if (not Path(self.path).is_absolute() or Path(self.name).name != self.name
                or any(value in self.name for value in ('"', "\\", "\r", "\n"))
                or type(self.size) is not int or self.size <= 0 or type(self.modified) is not int):
            raise ShelfError("An Audiobookshelf upload contains an invalid file entry.")

    @classmethod
    def prepare(cls, value):
        path = Path(value).resolve(strict=True)
        info = path.stat()
        if not S_ISREG(info.st_mode) or not info.st_size:
            raise ShelfError("An Audiobookshelf source file is empty or unavailable.")
        suffix = path.suffix
        name = safe_filename(path.stem, 180 - len(suffix.encode("utf-8"))) + suffix
        return cls(str(path), name, info.st_size, info.st_mtime_ns)

    def check(self, stream):
        info = fstat(stream.fileno())
        if not S_ISREG(info.st_mode) or (info.st_size, info.st_mtime_ns) != (self.size, self.modified):
            raise ShelfError("A saved file changed. Queue the book again from the Library.")


@dataclass(frozen=True)
class UploadBook:
    asin: str
    title: str
    author: str
    series: str
    files: tuple[UploadFile, ...]

    def __post_init__(self):
        if (not all(isinstance(value, str) for value in (self.title, self.asin, self.author, self.series))
                or not self.title.strip() or not any(Path(file.name).suffix.casefold() in AUDIO_SUFFIXES
                                                     for file in self.files)):
            raise ShelfError("An Audiobookshelf upload contains invalid book metadata.")

    @classmethod
    def prepare(cls, book, audio, cover=(), pdf=()):
        if not playable_audio(audio):
            raise ShelfError("This book has no complete saved M4B, M4A, or MP3 audio.")
        unique = {}
        names = set()
        for source in (*audio, *cover, *pdf):
            file = UploadFile.prepare(source)
            if file.path in unique:
                continue
            if file.name.casefold() in names:
                tag = sha256(file.path.encode()).hexdigest()[:12]
                stem, suffix = Path(file.name).stem, Path(file.name).suffix
                file = UploadFile(file.path, f"{stem[:190]}-{tag}{suffix}", file.size, file.modified)
            names.add(file.name.casefold())
            unique[file.path] = file
        return cls(book.get("asin") or "", book["title"], ", ".join(book.get("authors") or ()),
                   book.get("series") or "", tuple(unique.values()))

    @property
    def identity(self):
        return self.asin.strip().casefold() or (search_key(self.title), search_key(self.author))

    def saved_files(self, include_pdf):
        return self.files if include_pdf else tuple(file for file in self.files
                                                    if Path(file.name).suffix.casefold() != ".pdf")


def playable_audio(paths):
    return bool(paths) and all(Path(path).suffix.casefold() in AUDIO_SUFFIXES for path in paths)


def receipt_index(receipts, account, root):
    results = {}
    for receipt in sorted(receipts.glob("*.json"), key=_last_changed, reverse=True):
        try:
            data = read_json(receipt)
            if (not isinstance(data, dict) or data.get("account_id") != account
                    or not isinstance(data.get("asin"), str) or Path(data["root"]).resolve() != root):
                continue
            results.setdefault(data["asin"], []).append(data)
        except (KeyError, OSError, RuntimeError, TypeError, ValueError):
            continue
    return results


def archive_upload(book, records, root, *, matches=(), include_pdf=False):
    """Find one complete rendition and its recorded companion files."""
    converted, originals, cover, pdf = (), (), (), ()
    for data in records:
        try:
            groups, sizes = data["groups"], data.get("sizes", {})

            def saved(group, groups=groups, sizes=sizes):
                files = tuple(Path(value) for value in groups.get(group, ()))
                if not all(path.resolve().is_relative_to(root) and recorded_file(path, sizes) for path in files):
                    return ()
                return files

            preferred = saved("conversion")
            original = saved("audio")
            if not converted and playable_audio(preferred):
                converted = preferred
            if not originals and playable_audio(original):
                originals = original
            if not cover:
                cover = tuple(path for label in sorted(groups, key=_cover_priority, reverse=True)
                              if label == "cover" or label.startswith("cover-")
                              for path in saved(label) if path.suffix.casefold() in COVER_SUFFIXES)[:1]
            if include_pdf and not pdf:
                pdf = tuple(path for path in saved("pdf") if path.suffix.casefold() == ".pdf")
        except (AttributeError, KeyError, OSError, RuntimeError, TypeError, ValueError):
            continue
    audio = converted or originals or matches
    return UploadBook.prepare(book, audio, cover, pdf)


def receipt_upload(book, receipt, *, include_pdf):
    def saved(group):
        files = tuple(Path(value) for value in receipt.groups.get(group, ()))
        return files if all(recorded_file(path, receipt.sizes) for path in files) else ()

    audio = saved("conversion")
    if not playable_audio(audio):
        audio = saved("audio")
    if not playable_audio(audio):
        return None
    cover = tuple(path for group in sorted(receipt.groups, key=_cover_priority, reverse=True)
                  if group == "cover" or group.startswith("cover-")
                  for path in saved(group) if path.suffix.casefold() in COVER_SUFFIXES)[:1]
    return UploadBook.prepare(book, audio, cover, saved("pdf") if include_pdf else ())


def _cover_priority(name):
    size = name.removeprefix("cover-")
    return int(size) if size.isascii() and size.isdecimal() and len(size) <= 6 else 0


def _last_changed(path):
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return 0


def search_key(value):
    return " ".join(value.casefold().split())


def _text_component(value, *, fallback=""):
    text = value.strip()
    if not text:
        return fallback
    return safe_filename(text)


class ShelfClient:
    def __init__(self, server, token, *, timeout=30):
        self.server = normalize_server(server)
        self.url = urlsplit(self.server)
        self.token = validate_token(token)
        self.timeout = timeout

    def _request(self, method, path, *, body=None, headers=None, expect_json=False):
        connection = (HTTPSConnection if self.url.scheme == "https" else HTTPConnection)(
            self.url.hostname, self.url.port, timeout=self.timeout)
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json", **(headers or {})}
        try:
            connection.request(method, f"{self.url.path}/api/{path}", body=body, headers=headers)
            response = connection.getresponse()
            if 300 <= response.status < 400:
                raise ShelfError("Audiobookshelf redirected the request. Check the server URL.")
            if response.status in {401, 403}:
                raise ShelfError("Audiobookshelf refused access. Check the API token and upload permissions.")
            if response.status >= 400:
                raise ShelfError(f"Audiobookshelf returned HTTP {response.status}.")
            if expect_json:
                content = response.read(MAX_JSON + 1)
                if len(content) > MAX_JSON:
                    raise ShelfError("Audiobookshelf sent an unexpectedly large response.")
                result = loads(content)
                if not isinstance(result, dict):
                    raise ShelfError("Audiobookshelf returned an unexpected response.")
                return result
        except InterruptedError:
            raise
        except (OSError, HTTPException):
            raise ShelfError("DownAudible could not reach Audiobookshelf. Check the connection and try again.") from None
        except (JSONDecodeError, UnicodeError):
            raise ShelfError("Audiobookshelf returned an unexpected response.") from None
        finally:
            connection.close()

    def libraries(self):
        result = self._request("GET", "libraries", expect_json=True)
        entries = result.get("libraries")
        if not isinstance(entries, list):
            raise ShelfError("Audiobookshelf did not return a list of libraries.")
        libraries = []
        for entry in entries:
            if not isinstance(entry, dict) or entry.get("mediaType") != "book":
                continue
            identifier, name, folders = entry.get("id"), entry.get("name"), entry.get("folders")
            if not isinstance(identifier, str) or not isinstance(name, str) or not isinstance(folders, list):
                continue
            valid_folders = []
            for folder in folders:
                if not isinstance(folder, dict):
                    continue
                folder_id, path = folder.get("id"), folder.get("fullPath") or folder.get("path")
                if isinstance(folder_id, str) and folder_id and isinstance(path, str) and path:
                    valid_folders.append(ShelfFolder(folder_id, path))
            if identifier and valid_folders:
                libraries.append(ShelfLibrary(identifier, name, tuple(valid_folders)))
        return tuple(libraries)

    def _search(self, target, value):
        query = urlencode({"q": value, "limit": MATCH_LIMIT})
        library = quote(target.library_id, safe="")
        data = self._request("GET", f"libraries/{library}/search?{query}", expect_json=True)
        books = data.get("book")
        if not isinstance(books, list):
            raise ShelfError("Audiobookshelf did not return book search results.")
        return books

    def _already_exists(self, target, book):
        asin, title, author = search_key(book.asin), search_key(book.title), search_key(book.author)
        conflict = False
        for query in dict.fromkeys(value for value in (book.asin, book.title) if value):
            for hit in self._search(target, query):
                if not isinstance(hit, dict):
                    continue
                item = hit.get("libraryItem") or {}
                metadata = (item.get("media") or {}).get("metadata") or {}
                candidate_asin = search_key(metadata.get("asin") or "")
                if asin and candidate_asin and asin == candidate_asin:
                    return True
                candidate_author = metadata.get("authorName") or ", ".join(
                    value.get("name") or "" for value in metadata.get("authors", ()) if isinstance(value, dict))
                if title != search_key(metadata.get("title") or "") or author != search_key(candidate_author):
                    continue
                if not asin or not candidate_asin:
                    return True
                conflict = True
        if conflict:
            raise ShelfError("A different edition with this title and author is already in Audiobookshelf.")
        return False

    def upload(self, target, book, cancel, *, include_pdf=True):
        if self.server != normalize_server(target.server):
            raise ShelfError("Connect to the server selected for this upload.")
        if cancel.is_set():
            raise InterruptedError
        if self._already_exists(target, book):
            return "Already in library"
        fields = {
            "title": _text_component(book.title, fallback="Audiobook"),
            "author": _text_component(book.author),
            "series": _text_component(book.series),
            "library": target.library_id,
            "folder": target.folder_id,
        }
        with ExitStack() as stack:
            files = []
            for file in book.saved_files(include_pdf):
                try:
                    source = stack.enter_context(Path(file.path).open("rb"))
                    file.check(source)
                except OSError:
                    raise ShelfError("A saved file is unavailable. Queue the book again from the Library.") from None
                files.append((file, source))
            form = Multipart(fields, files, cancel)
            self._request("POST", "upload", body=iter(form), headers={
                "Content-Type": f"multipart/form-data; boundary={form.boundary}",
                "Content-Length": str(form.length),
            })
        return "Sent to server"


class Multipart:
    def __init__(self, fields, files, cancel):
        self.boundary = f"downaudible-{uuid4().hex}"
        self.cancel = cancel
        self.fields = [
            self._part(f'Content-Disposition: form-data; name="{name}"', value.encode("utf-8")) + b"\r\n"
            for name, value in fields.items() if value
        ]
        self.files = [
            (self._part(f'Content-Disposition: form-data; name="file{index}"; filename="{file.name}"'
                        f'\r\nContent-Type: {guess_type(file.name)[0] or "application/octet-stream"}', b""),
             file, source)
            for index, (file, source) in enumerate(files)
        ]
        self.end = f"--{self.boundary}--\r\n".encode("ascii")
        self.length = (sum(map(len, self.fields)) + len(self.end)
                       + sum(len(header) + file.size + 2 for header, file, _source in self.files))

    def _part(self, header, content):
        return f"--{self.boundary}\r\n{header}\r\n\r\n".encode("utf-8") + content

    def __iter__(self):
        yield from self.fields
        for header, file, source in self.files:
            yield header
            left = file.size
            while left:
                if self.cancel.is_set():
                    raise InterruptedError
                chunk = source.read(min(left, TRANSFER_BLOCK))
                if not chunk:
                    raise ShelfError("A saved file changed during upload. Queue the book again from the Library.")
                yield chunk
                left -= len(chunk)
            file.check(source)
            yield b"\r\n"
        yield self.end


@dataclass
class UploadEntry:
    id: str
    target: UploadTarget
    book: UploadBook
    include_pdf: bool
    date: float
    status: str = "Waiting"
    detail: str = ""

    @classmethod
    def read(cls, data):
        raw = dict(data)
        raw["target"] = UploadTarget(**raw["target"])
        book = raw["book"]
        raw["book"] = UploadBook(**{**book, "files": tuple(UploadFile(**file) for file in book["files"])})
        result = cls(**raw)
        if (not isinstance(result.id, str) or type(result.include_pdf) is not bool
                or type(result.date) not in (int, float) or not isinstance(result.detail, str)
                or result.status not in {"Waiting", "Uploading", "Failed", "Sent", "Already in library"}):
            raise ShelfError("The Audiobookshelf queue contains invalid upload information.")
        if result.status == "Uploading":
            result.status = "Waiting"
        return result


class UploadQueue:
    def __init__(self, path, *, changed=None, client=ShelfClient):
        self.path, self.changed, self.client = path, changed, client
        self.condition = Condition()
        self.stop = Event()
        self.target, self.token = None, ""
        self.auto_upload, self.include_pdf = False, False
        self.warning, self.worker = "", None
        self.entries = self._load()

    def _load(self):
        try:
            return [UploadEntry.read(entry) for entry in (read_json(self.path) or [])]
        except (OSError, TypeError, ValueError, KeyError):
            self.warning = "The saved Audiobookshelf upload queue could not be read. The original file was preserved."
            return []

    def _write(self):
        if self.warning:
            raise ShelfError(self.warning)
        try:
            write_json(self.path, [asdict(entry) for entry in self.entries])
        except OSError:
            raise ShelfError("The Audiobookshelf upload queue could not be saved.") from None

    def configure(self, target, token, *, automatic=False, include_pdf=False):
        with self.condition:
            self.target, self.token = target, token
            self.auto_upload, self.include_pdf = automatic, include_pdf
            self._wake()

    def _wake(self):
        if self.target and self.token and self.worker is None and not self.stop.is_set() and not self.warning:
            self.worker = Thread(target=self._drain, daemon=True, name="Audiobookshelf uploads")
            self.worker.start()
        self.condition.notify_all()

    def upload_automatically(self, book, receipt):
        with self.condition:
            if not self.auto_upload or not self.target or not self.token or self.stop.is_set():
                return
            candidate = receipt_upload(book, receipt, include_pdf=self.include_pdf)
            if candidate:
                self.enqueue([candidate], automated=True)

    def enqueue(self, books: Iterable[UploadBook], *, automated=False, expected_target=None):
        with self.condition:
            if not self.target or not self.token:
                raise ShelfError("Connect to an Audiobookshelf library and folder in Settings first.")
            if expected_target and expected_target.identity != self.target.identity:
                raise ShelfError("The Audiobookshelf destination changed. Queue the books again for the new destination.")
            if self.stop.is_set():
                return 0
            prior = self.entries.copy()
            count = 0
            for book in books:
                matches = [entry for entry in self.entries if entry.target.identity == self.target.identity
                           and entry.book.identity == book.identity]
                if any(entry.status != "Failed" for entry in matches) or (automated and matches):
                    continue
                self.entries = [entry for entry in self.entries if entry not in matches or entry.status != "Failed"]
                self.entries.append(UploadEntry(uuid4().hex, self.target, book, self.include_pdf, time()))
                count += 1
            if count:
                finished = [entry for entry in self.entries if entry.status in {"Sent", "Already in library"}]
                excess = finished[:-HISTORY_LIMIT]
                self.entries = [entry for entry in self.entries if entry not in excess]
                try:
                    self._write()
                except ShelfError:
                    self.entries = prior
                    raise
                self._wake()
            return count

    def snapshot(self):
        with self.condition:
            return tuple(asdict(entry) for entry in reversed(self.entries))

    def retry(self, identifiers):
        with self.condition:
            selected = [entry for entry in self.entries if entry.status == "Failed"
                        and (not identifiers or entry.id in identifiers) and self.target
                        and entry.target.identity == self.target.identity]
            previous = [(entry, entry.detail) for entry in selected]
            for entry, _detail in previous:
                entry.status, entry.detail = "Waiting", ""
            if selected:
                try:
                    self._write()
                except ShelfError:
                    for entry, detail in previous:
                        entry.status, entry.detail = "Failed", detail
                    raise
                self._wake()
            return len(selected)

    def close(self):
        self.stop.set()
        with self.condition:
            self.condition.notify_all()

    def _next(self):
        if not self.target or not self.token or self.warning:
            return None
        return next((entry for entry in self.entries if entry.status == "Waiting" and
                     entry.target.identity == self.target.identity), None)

    def _drain(self):
        while True:
            with self.condition:
                self.condition.wait_for(lambda: self.stop.is_set() or self._next())
                if self.stop.is_set():
                    return
                entry = self._next()
                entry.status, token = "Uploading", self.token
                try:
                    self._write()
                except ShelfError as error:
                    entry.status, self.warning = "Waiting", str(error)
                    continue
            try:
                client = self.client(entry.target.server, token)
                message = client.upload(entry.target, entry.book, self.stop, include_pdf=entry.include_pdf)
                status = "Already in library" if message == "Already in library" else "Sent"
            except InterruptedError:
                status, message = "Waiting", "Upload interrupted. DownAudible will resume it when reopened."
            except (ShelfError, OSError, TypeError, AttributeError, KeyError) as error:
                status = "Failed"
                message = str(error) if isinstance(error, ShelfError) else "Audiobookshelf returned an unexpected result."
            with self.condition:
                entry.status, entry.detail = status, message
                try:
                    self._write()
                except ShelfError as error:
                    self.warning = str(error)
            if self.changed:
                self.changed(status, message)

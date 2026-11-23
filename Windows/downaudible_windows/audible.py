"""Run the shared Audible helper and store Windows account sessions with DPAPI."""

from __future__ import annotations

import base64
import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from contextlib import contextmanager
from ctypes import wintypes
from hashlib import sha256
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import url2pathname

MARKETPLACES = {
    "au": "Australia", "br": "Brazil", "ca": "Canada", "fr": "France", "de": "Germany",
    "in": "India", "it": "Italy", "jp": "Japan", "es": "Spain", "uk": "United Kingdom",
    "us": "United States",
}
LEGACY_MARKETPLACES = {"de", "uk", "us"}

ERROR_MESSAGES = {
    "chapterRepairFile": "DownAudible couldn’t read the selected chapter JSON file.",
    "chapterRepairMetadata": "This source does not provide usable Audible chapter data.",
    "chapterRepairEdition": "The chapter data belongs to a different Audible edition.",
    "aaxUnavailable": "Audible did not offer an AAX download. Choose AAX with fallback or AAXC in Settings > Downloads and retry.",
    "aaxcUnavailable": "Audible did not offer an AAXC download for this title.",
    "accountInUse": "Wait for the current batch to finish before changing, signing out, or removing the account.",
    "accountMismatch": "Audible signed in to a different account. Start again and use the Amazon sign-in for the selected profile.",
    "accountVerification": "DownAudible could not confirm the same Audible account. Check the selected profile’s sign-in and try again.",
    "activation": "Audible could not provide activation bytes for this account.",
    "authImport": "This file does not contain an Audible CLI account that can be imported.",
    "openAudibleFile": "Choose an OpenAudible credentials.json file with a supported account.",
    "openAudibleChanged": "The selected profile changed. Choose the OpenAudible file again.",
    "openAudibleVerify": "Audible could not verify this OpenAudible sign-in. Reconnect the account in OpenAudible and choose its credentials file again.",
    "authorization": "Audible rejected this session. Sign in again in Accounts.",
    "cancelled": "The operation was cancelled.",
    "cliConfig": "No usable profiles were found in this Audible CLI configuration file.",
    "credentialSignInFailed": "Audible could not sign in with those credentials. Check your details or use Web Browser.",
    "diskFull": "There is no space left on the destination drive.",
    "deviceDeregistrationConfirmation": "Confirm deregistration for the selected device first.",
    "deviceDeregistration": "Audible could not confirm that this device was deregistered. Check your sign-in and try again.",
    "downloadResponse": "The download server returned an unexpected response. Try again later.",
    "exportPassword": "Enter a password for the encrypted account file.",
    "extraUnavailable": "Audible does not offer this companion file for the title.",
    "fileAccess": "DownAudible could not read or write the selected file.",
    "helper": "The Audible helper could not be started. Check the installation and try again.",
    "importMarketplace": "Choose the Audible marketplace for this account.",
    "importPassword": "Enter the password for this encrypted Audible CLI file.",
    "importPasswordIncorrect": "The file could not be decrypted with that password.",
    "incompleteResponse": "The download is incomplete. Choose Retry Incomplete in Downloads to resume.",
    "invalidRedirect": "Copy the full address from the last page of Audible sign-in and try again.",
    "licenseDenied": "Audible declined the download licence for this title.",
    "licenseEntitlement": "Audible could not confirm download rights for this account.",
    "licenseResponse": "Audible returned an unreadable download licence. Try again later.",
    "licenseThrottled": "Audible is limiting download licences for this account. Wait before retrying.",
    "listeningStatsYear": "Enter a start year from 1997 through the current year.",
    "listeningStatsResponse": "Audible returned unreadable listening statistics. Try again later.",
    "annotationsResponse": "Audible returned unreadable bookmarks or notes. Try again later.",
    "network": "Could not reach Audible. Check your connection and try again.",
    "notFound": "Audible could not find the requested title.",
    "notPublished": "The title has not been released. Refresh the library after the release date.",
    "notSignedIn": "Sign in to Audible to continue.",
    "offlineRestricted": "Audible does not allow offline downloads of this title for this account.",
    "partsUnavailable": "Audible did not supply all the audio parts. Refresh the library and retry.",
    "podcastSeries": "Choose an individual podcast episode to download.",
    "rateLimited": "Audible is receiving too many requests. Try again shortly.",
    "requestRejected": "Audible rejected the request.",
    "serverUnavailable": "Audible is temporarily unavailable. Try again shortly.",
    "service": "Audible did not complete the request.",
    "signInFailed": "Audible did not complete sign-in. Open a new sign-in page and try again.",
    "sourceRejected": "The download server refused the file. Retry or check the title in Audible.",
    "stagingFileAccess": "DownAudible could not access its download files. Check the destination and try again.",
    "timeout": "Audible did not respond in time. Try again.",
    "unavailable": "Audible did not provide a download for this title.",
    "vault": "DownAudible could not access the saved Windows account session.",
    "widevineAudio": "DownAudible could not prepare the Widevine stereo audio.",
    "widevineConsent": "Enable Widevine for this account to allow CDM provisioning.",
    "widevineLicense": "Audible could not supply a Widevine licence for this title.",
    "widevineManifest": "Audible returned an unreadable Widevine audio description.",
    "widevineProvision": "The Widevine provider could not provision this Audible account. Try again later.",
    "widevineRegistration": "Widevine requires a compatible Android Audible sign-in. Use Android Browser (Advanced) or import a compatible account.",
}


class AudibleError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(ERROR_MESSAGES.get(code, ERROR_MESSAGES["service"]))


class _DataBlob(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]


def _dpapi(data, *, protect):
    if os.name != "nt":
        raise AudibleError("vault")
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    blob_pointer = ctypes.POINTER(_DataBlob)
    action = crypt.CryptProtectData if protect else crypt.CryptUnprotectData
    action.argtypes = [blob_pointer, ctypes.c_void_p, blob_pointer, ctypes.c_void_p,
                       ctypes.c_void_p, wintypes.DWORD, blob_pointer]
    action.restype = wintypes.BOOL
    source_buffer = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    source = _DataBlob(len(data), source_buffer)
    result = _DataBlob()
    # The current Windows user can decrypt the result without a system prompt.
    try:
        if not action(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(result)):
            raise AudibleError("vault")
        return ctypes.string_at(result.data, result.size)
    finally:
        ctypes.memset(source.data, 0, source.size)
        if result.data:
            ctypes.memset(result.data, 0, result.size)
            kernel.LocalFree(result.data)


def write_atomic(path, contents):
    """Replace a file only after its complete replacement has been written."""
    path = Path(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def cli_config_path():
    audible_dir = Path(os.environ.get("AUDIBLE_CONFIG_DIR") or Path.home() / ".audible")
    return audible_dir.expanduser() / "config.toml"


def auth_file_path(uri):
    url = urlsplit(uri)
    if url.scheme != "file":
        raise AudibleError("authImport")
    if url.netloc and url.netloc.casefold() != "localhost":
        return Path(url2pathname(f"//{url.netloc}{url.path}"))
    return Path(url2pathname(url.path))


class AudibleClient:
    _public_commands = frozenset({
        "beginSignIn", "completeSignIn", "credentialSignIn", "cliProfiles", "inspectAuthFile", "importAuthFile",
        "inspectOpenAudible", "importOpenAudible",
    })

    def __init__(self, resource_dir, data_dir, *, demo=False):
        self.resource_dir = Path(resource_dir)
        self.data_dir = Path(data_dir)
        self.demo = demo
        self._session_lock = threading.RLock()
        self._demo_signed_out = set()
        self._demo_wishlist = {book["asin"]: book for book in demo_catalog()[:2]}

    def _session_path(self, account_id):
        if not isinstance(account_id, str) or not re.fullmatch(r"[a-zA-Z0-9-]{1,64}", account_id):
            raise AudibleError("notSignedIn")
        return self.data_dir / "Accounts" / f"{account_id}.dpapi"

    def session(self, account_id):
        path = self._session_path(account_id)
        if self.demo:
            if account_id in self._demo_signed_out:
                raise AudibleError("notSignedIn")
            return '{"demo":true}'
        with self._session_lock:
            try:
                encrypted = path.read_bytes()
                return _dpapi(encrypted, protect=False).decode("utf-8")
            except FileNotFoundError:
                raise AudibleError("notSignedIn") from None
            except (OSError, UnicodeError):
                raise AudibleError("vault") from None

    def has_session(self, account_id):
        try:
            self.session(account_id)
        except AudibleError as error:
            if error.code != "notSignedIn":
                raise
            return False
        return True

    def save_session(self, account_id, session):
        path = self._session_path(account_id)
        if self.demo:
            self._demo_signed_out.discard(account_id)
            return
        with self._session_lock:
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                write_atomic(path, _dpapi(session.encode("utf-8"), protect=True))
            except (OSError, UnicodeError):
                raise AudibleError("vault") from None

    def remove_session(self, account_id):
        if self.demo:
            self._demo_signed_out.add(account_id)
            return
        with self._session_lock:
            try:
                self._session_path(account_id).unlink(missing_ok=True)
            except OSError:
                raise AudibleError("vault") from None

    @contextmanager
    def session_change(self, account_id, session, *, previous_registration=None):
        """Restore the account's encrypted session if its settings cannot be saved."""
        path = self._session_path(account_id)
        with self._session_lock:
            if previous_registration is not None:
                reference, expected = previous_registration
                try:
                    if self.session(reference) != expected:
                        raise AudibleError("accountVerification")
                except AudibleError as error:
                    if error.code == "notSignedIn":
                        raise AudibleError("accountVerification") from None
                    raise
            previous = None
            demo_signed_out = account_id in self._demo_signed_out
            if not self.demo:
                try:
                    previous = path.read_bytes()
                except FileNotFoundError:
                    pass
                except OSError:
                    raise AudibleError("vault") from None
            if session is None:
                self.remove_session(account_id)
            else:
                self.save_session(account_id, session)
            try:
                yield
            except Exception:
                try:
                    if self.demo:
                        if demo_signed_out:
                            self._demo_signed_out.add(account_id)
                        else:
                            self._demo_signed_out.discard(account_id)
                    elif previous is None:
                        path.unlink(missing_ok=True)
                    else:
                        write_atomic(path, previous)
                except OSError:
                    raise AudibleError("vault") from None
                raise

    def update_session(self, account_id, previous, current):
        with self._session_lock:
            try:
                if self.session(account_id) == previous:
                    self.save_session(account_id, current)
            except AudibleError as error:
                if error.code != "notSignedIn":
                    raise

    def _widevine_reference(self, account_id):
        self._session_path(account_id)
        return "widevine-" + sha256(account_id.encode("ascii")).hexdigest()[:55]

    def widevine_cdm(self, account_id):
        if self.demo:
            return None
        try:
            return self.session(self._widevine_reference(account_id))
        except AudibleError as error:
            if error.code != "notSignedIn":
                raise
            return None

    def provision_widevine(self, account_id):
        current_session = self.session(account_id)
        if self.widevine_cdm(account_id):
            return None
        result = self.run("provisionWidevine", session=current_session, consent=True)
        cdm = result.get("cdm") if isinstance(result, dict) else None
        try:
            if (isinstance(cdm, str) and 0 < len(cdm) <= 1_048_576
                    and base64.b64decode(cdm, validate=True) and self.session(account_id) == current_session):
                return cdm
        except ValueError:
            pass
        raise AudibleError("widevineProvision")

    def widevine_change(self, account_id, cdm):
        return self.session_change(self._widevine_reference(account_id), cdm)

    def _command_line(self):
        helper = self.resource_dir / "Audible" / "audible_helper.py"
        if helper.is_file():
            python = Path(os.environ.get("DOWNAUDIBLE_PYTHON") or sys.executable)
            if python.name.casefold() == "pythonw.exe":
                python = python.with_name("python.exe")
            return [str(python), "-X", "utf8", str(helper)]

        project = Path(__file__).resolve().parents[2] / "Scripts" / "Audible"
        source = project / "audible_helper.py"
        uv = shutil.which("uv")
        if source.is_file() and uv:
            return [uv, "run", "--project", str(project), "--locked", "--python", "3.13",
                    "python", "-X", "utf8", str(source)]
        if source.is_file():
            return [sys.executable, "-X", "utf8", str(source)]
        raise AudibleError("helper")

    def run(self, command, *, account_id=None, session=None, cancel=None, progress=None, respond=None, **fields):
        if cancel is not None and cancel.is_set():
            raise AudibleError("cancelled")
        local_chapters = command == "chapterRepair" and bool(fields.get("file"))
        if command not in self._public_commands and session is None and not local_chapters:
            session = self.session(account_id)
        if self.demo and not local_chapters:
            return self._demo_result(command, fields)
        request = {"command": command, **fields}
        if session is not None:
            request["session"] = session
        return self._exchange(request, cancel=cancel, progress=progress, respond=respond)

    def _exchange(self, request, *, cancel, progress, respond):
        try:
            process = subprocess.Popen(
                self._command_line(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, encoding="utf-8", creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except OSError:
            raise AudibleError("helper") from None
        finished = threading.Event()
        try:
            if cancel is not None:
                threading.Thread(target=self._cancel_process, args=(process, cancel, finished), daemon=True).start()
            self._send(process, request)
            if respond is None:
                process.stdin.close()
            for raw in process.stdout:
                message = json.loads(raw)
                if not isinstance(message, dict):
                    raise AudibleError("helper")
                if "error" in message:
                    raise AudibleError(str(message["error"]))
                if "result" in message:
                    if cancel is not None and cancel.is_set():
                        raise AudibleError("cancelled")
                    return message["result"]
                if "progress" in message and progress is not None:
                    progress(message["progress"])
                if "signInChallenge" in message:
                    answer = respond(message["signInChallenge"]) if respond is not None else None
                    if answer is None:
                        raise AudibleError("cancelled")
                    self._send(process, {"answer": answer})
            raise AudibleError("cancelled" if cancel is not None and cancel.is_set() else "helper")
        except (OSError, UnicodeError, json.JSONDecodeError):
            raise AudibleError("cancelled" if cancel is not None and cancel.is_set() else "helper") from None
        finally:
            finished.set()
            try:
                process.stdin.close()
            except OSError:
                pass
            process.stdout.close()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    @staticmethod
    def _send(process, message):
        process.stdin.write(json.dumps(message, ensure_ascii=True, separators=(",", ":")) + "\n")
        process.stdin.flush()

    @staticmethod
    def _cancel_process(process, cancel, finished):
        while not finished.wait(0.1):
            if cancel.is_set():
                try:
                    process.terminate()
                except OSError:
                    pass
                return

    def _demo_result(self, command, fields):
        match command:
            case "library":
                return demo_books()
            case "wishlist":
                return list(self._demo_wishlist.values())
            case "catalog":
                query = fields.get("query", "").casefold()
                return [book for book in demo_catalog() if query in f'{book["title"]} {book["asin"]}'.casefold()]
            case "wishlistAdd":
                self._demo_wishlist.update((book["asin"], book) for book in demo_catalog()
                                           if book["asin"] in fields.get("asins", []))
                return {}
            case "wishlistRemove":
                for asin in fields.get("asins", []):
                    self._demo_wishlist.pop(asin, None)
                return {}
            case "activation":
                return {"activationBytes": "00000000", "session": '{"demo":true}'}
            case "provisionWidevine":
                return {"cdm": "ZGVtbw=="}
            case "checkTitle":
                return {"asin": fields["asin"], "offers": [
                    {"format": "aax", "status": "available", "codec": "AAC-LC", "bitrateKbps": 128, "channels": 2},
                    {"format": "aaxc", "status": "notOffered", "reason": "aaxcUnavailable"},
                    {"format": "widevine", "status": "notChecked", "reason": "widevineDisabled"},
                ]}
            case "listeningStats":
                months = [("2025-11", 49_500_000), ("2026-08", 98_400_000), ("2026-09", 0), ("2026-10", 183_600_000)]
                return {"months": [{"month": month, "durationMilliseconds": duration} for month, duration in months
                                   if int(month[:4]) >= fields["startYear"]]}
            case "annotations":
                return {"entries": [
                    {"kind": "bookmark", "positionMilliseconds": 83_000, "text": "Opening chapter"},
                    {"kind": "note", "positionMilliseconds": 852_000, "text": "The narrator introduces the map here.\nReturn to this passage with the companion PDF."},
                    {"kind": "bookmark", "positionMilliseconds": 2_340_000, "text": "End of Part One"},
                ]}
            case "deviceRegistration":
                return {"kind": "android", "name": "Audible for Android", "marketplace": "uk", "serialSuffix": "1234"}
            case "deregisterDevice":
                if fields.get("confirmed") is not True:
                    raise AudibleError("deviceDeregistrationConfirmation")
                return True
            case "beginSignIn":
                attempt = {"url": "https://example.com/sign-in", "serial": "demo", "verifier": "demo"}
                if fields.get("deviceProfile") == "android":
                    attempt["registrationContext"] = "fixture-context"
                return attempt
            case "completeSignIn" | "credentialSignIn":
                return {"session": '{"demo":true}'}
            case "inspectAuthFile":
                return True
            case "importAuthFile":
                return {"session": '{"demo":true}', "marketplace": fields.get("marketplace") or "uk"}
            case "inspectOpenAudible":
                return [{"name": "Demo Account", "marketplace": "uk", "isDefault": True, "checkpoint": "1" * 64},
                        {"name": "Demo Account 2", "marketplace": "us", "isDefault": False, "checkpoint": "2" * 64}]
            case "importOpenAudible":
                marketplace = {"1" * 64: "uk", "2" * 64: "us"}.get(fields.get("checkpoint"))
                if marketplace is None:
                    raise AudibleError("openAudibleChanged")
                return {"session": '{"demo":true}', "marketplace": marketplace}
            case "cliProfiles":
                profile_file = Path(fields["file"]).with_name("demo-account.json").resolve()
                return [{"name": "Demo Account", "authFile": profile_file.as_uri(), "marketplace": "uk",
                         "isDefault": True, "requiresPassword": True}]
            case "exportAuthFile":
                return '{"demoAccount":true}\n'
            case "chapters":
                return [{"title": "Chapter 1", "startSeconds": 0, "durationSeconds": 30}]
            case _:
                raise AudibleError("service")


def demo_books():
    return [
        {"asin": f"DEMO{i:06d}", "title": f"Demo Book {i}", "authors": [f"Demo Author {(i + 1) // 2}"],
         "narrators": [f"Demo Narrator {i}"], "series": "Demo Series" if i < 4 else None,
         "seriesSequence": str(i) if i < 4 else None, "isDownloadable": i != 6,
         "downloadUnavailableReason": "offlineRestricted" if i == 6 else None,
         "durationSeconds": 3600 + i * 1320, "purchaseDate": f"2026-10-0{i}", "releaseDate": f"202{i}-04-17",
         "hasPDF": i in (1, 3), "language": "English", "genres": ["Fiction", "Mystery"],
         "description": "A sample audiobook used to demonstrate the library."}
        for i in range(1, 7)
    ]


def demo_catalog():
    return [
        {"asin": f"WISH{i:06d}", "title": f"Demo Wish List Book {i}", "authors": [f"Demo Author {i}"],
         "narrators": [f"Demo Narrator {i}"], "durationSeconds": 3600 + i * 420,
         "description": "A sample result from the Audible catalogue.", "isDownloadable": False}
        for i in range(1, 5)
    ]

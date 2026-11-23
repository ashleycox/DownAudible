"""Download and local conversion work shared by the transfer views."""

import json
import os
import re
import shutil
import subprocess
import wave
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from functools import partial
from hashlib import sha256
from pathlib import Path
from threading import BoundedSemaphore, Lock
from uuid import uuid4

from .archive import ArchiveLayout, recorded_file
from .audible import AudibleError
from .media import (
    AUDIO_FORMATS,
    ActivationRequired,
    ConversionOptions,
    MediaInput,
    read_voucher,
    source_revision,
)
from .media_recycle import recycle_source
from .pacing import DownloadPacer
from .refusal import Refusals
from .state import api_options, read_json, write_json

SECRET_SETTINGS = ("activation_bytes", "audible_key", "audible_iv")
AUDIO_STAGING_SUFFIXES = (".aax", ".aaxc", ".aa", ".mp3", ".m4a", ".m4b")
PLAYER_STEPS = {"audio": "open-original", "conversion": "open-converted"}


def stable_id(*parts):
    return sha256(json.dumps(parts, ensure_ascii=True, sort_keys=True).encode()).hexdigest()


def is_reparse(path):
    flags = getattr(path.lstat(), "st_file_attributes", 0) if path.exists() or path.is_symlink() else 0
    return bool(flags & 0x400) or path.is_symlink()


@dataclass
class Staging:
    root: Path
    account: str
    asin: str
    destination: Path
    api: dict

    @property
    def path(self):
        key = stable_id(self.account, self.asin, os.path.normcase(str(self.destination)),
                        {name: self.api.get(name) for name in ("format", "quality", "preferWholeBookDownloads")})
        return self.root / key

    def prepare(self, restart=False):
        self.root.mkdir(parents=True, exist_ok=True)
        if is_reparse(self.root) or is_reparse(self.path):
            raise ValueError("The partial download folder points outside DownAudible data.")
        if restart and self.path.exists():
            shutil.rmtree(self.path)
        self.path.mkdir(exist_ok=True)
        return self.path


def staged_file(folder, value, *, must_exist=True):
    if not isinstance(value, str) or not value or Path(value).name != value or any(c in value for c in "/\\:"):
        raise ValueError("The helper returned an invalid output filename.")
    path = folder / value
    if is_reparse(path) or (must_exist and not path.is_file()):
        raise ValueError("The helper did not save a usable file.")
    return path


def copy_atomic(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    directory = destination.parent
    initial = directory.stat()
    if is_reparse(directory) or directory.resolve() != directory:
        raise ValueError("The archive folder points to another location.")
    revision = source_revision(source)
    temporary = destination.with_name(f".{uuid4().hex}.partial")
    try:
        shutil.copyfile(source, temporary)
        current = directory.stat()
        if (current.st_dev, current.st_ino) != (initial.st_dev, initial.st_ino) or directory.resolve() != directory:
            raise ValueError("The archive folder changed before the file could be saved.")
        if source_revision(source) != revision:
            raise ValueError("The source changed before the file could be saved.")
        if os.name == "nt":
            temporary.rename(destination)
        else:
            os.link(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def voucher_reference(path):
    stat = path.stat()
    return "voucher-" + stable_id(str(path.resolve()).casefold(), stat.st_size, stat.st_mtime_ns)[:56]


def file_revision(stat):
    return [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns]


class DownloadReceipt:
    def __init__(self, path, account, asin, root, update, *, legacy_paths=()):
        self.path = path
        self.account, self.asin, self.root = account, asin, root
        self.update = update
        saved = read_json(path)
        for legacy_path in legacy_paths:
            if saved is not None:
                break
            saved = read_json(legacy_path)
        saved = saved or {}
        self.sizes = dict(saved.get("sizes", {}))
        self.files = [Path(value) for value in saved.get("files", ())]
        self.files = [path for path in self.files if recorded_file(path, self.sizes)]
        valid = {str(path) for path in self.files}
        self.completed = set(saved.get("completed", ()))
        self.groups = {}
        for name, paths in saved.get("groups", {}).items():
            if all(path in valid for path in paths):
                self.groups[name] = paths
            else:
                self.completed.discard(name)
                self.completed.discard(PLAYER_STEPS.get(name))
        if "open" in self.completed:
            if self.groups.get("conversion"):
                self.completed.add(PLAYER_STEPS["conversion"])
            self.completed.remove("open")
        self.sizes = {path: size for path, size in self.sizes.items() if path in valid}
        self.cleanup = list(saved.get("cleanup", ()))

    def save(self):
        write_json(self.path, {
            "asin": self.asin, "account_id": self.account, "root": str(self.root),
            "files": [str(path) for path in self.files], "completed": sorted(self.completed),
            "groups": self.groups, "sizes": self.sizes, "cleanup": self.cleanup,
        })

    def mark(self, step, outputs=()):
        if outputs:
            self.sizes.update({str(path): path.stat().st_size for path in outputs})
            self.groups[step] = [str(path) for path in outputs]
            self.files.extend(path for path in outputs if path not in self.files)
            self.completed.discard(PLAYER_STEPS.get(step))
        self.completed.add(step)
        self.save()
        self.update("Saving files", files=self.files)


class JobRunner:
    def __init__(self, data_dir, client, tools, *, demo=False, completed_download=None, widevine_enabled=None):
        self.data_dir, self.client, self.tools, self.demo = data_dir, client, tools, demo
        self.completed_download = completed_download
        self.widevine_enabled = widevine_enabled
        self.output_lock = Lock()
        self.reserved_outputs = set()
        self.limits_lock = Lock()
        self.limits = {}
        self.pacer = DownloadPacer(data_dir / "Download Usage.json")
        self.refusals = Refusals(data_dir / "Download Refusals.json")

    def widevine_download_fields(self, account, options):
        if account and options.get("format") == "preferAAX" and self.widevine_enabled:
            if self.widevine_enabled(account) and (cdm := self.client.widevine_cdm(account)):
                return {"widevineCDM": cdm, "ffmpeg": str(self.tools.ffmpeg)}
        return {}

    @contextmanager
    def transfer_slot(self, kind, settings, stop, update):
        limit = settings.get(f"{kind}_limit", 3 if kind == "download" else 2)
        with self.limits_lock:
            available = self.limits.setdefault((kind, limit), BoundedSemaphore(limit))
        if stop.is_set():
            raise InterruptedError("Transfer cancelled.")
        if not available.acquire(blocking=False):
            update(f"Waiting for an available {kind} slot")
            while not available.acquire(timeout=0.15):
                if stop.is_set():
                    raise InterruptedError("Transfer cancelled.")
        try:
            if stop.is_set():
                raise InterruptedError("Transfer cancelled.")
            yield
        finally:
            available.release()

    def stage_for(self, job, settings):
        if job["kind"] != "Download":
            return None
        directory = Path(job.get("options", {}).get("destination") or settings["archive_root"]).resolve()
        return Staging(self.data_dir / "Partial Downloads", job.get("account_id") or "",
                       job["book"]["asin"], directory, api_options(settings))

    def has_partial(self, job, settings):
        if job["kind"] != "Download" or not job.get("options", {}).get("downloadAudio", True):
            return False
        try:
            stage = self.stage_for(job, settings)
            folder = stage.path
            if is_reparse(stage.root) or is_reparse(folder):
                return False
        except (KeyError, OSError, TypeError, ValueError):
            return False
        for directory in (folder, folder / "Conversion Source"):
            try:
                if is_reparse(directory) or not directory.is_dir():
                    continue
                for path in directory.iterdir():
                    name = path.name.casefold().removesuffix(".partial")
                    if name.startswith(".") or not name.endswith(AUDIO_STAGING_SUFFIXES):
                        continue
                    if not is_reparse(path) and path.is_file() and path.stat().st_size > 0:
                        return True
            except OSError:
                continue
        return False

    def run(self, job, settings, stop, update):
        if job["kind"] == "Download":
            return self.download(job, settings, stop, update)
        return self.convert_local(job, settings, stop, update)

    def download(self, job, settings, stop, update):
        book = job["book"]
        options = job["options"]
        asin = book["asin"]
        account = job.get("account_id")
        api = api_options(settings)
        stage = self.stage_for(job, settings)
        layout = ArchiveLayout.from_settings(settings, stage.destination)
        folder = stage.prepare(job.get("restart", False))
        replacement = job.get("replacement_id") or (job["id"] if job.get("restart") else None)
        directory = self.data_dir / "Receipts"
        legacy_paths = ()
        if replacement or settings["existing_files"] == "new" or options.get("repair") or job.get("pdf_backfill"):
            receipt_id = replacement or job["id"]
        else:
            names = asdict(layout)
            names["root"] = os.path.normcase(str(layout.root))
            file_options = {key: api.get(key) for key in (
                "format", "quality", "preferWholeBookDownloads", "coverSizes", "chapterStyle",
            )}
            preferences = settings["conversion"]
            receipt_id = stable_id(account, asin, names, file_options, self._output_recipe(preferences))
            previous_id = stable_id(account, asin, names, file_options, preferences)
            legacy_folder = layout.folder_template if "folder_template" in settings else None
            legacy_id = stable_id(
                account, asin, str(layout.root), legacy_folder, settings.get("filename_template"),
                settings.get("chapter_filename_template"), api, options, preferences,
            )
            legacy_paths = tuple(directory / f"{key}.json" for key in (previous_id, legacy_id) if key != receipt_id)
        receipt = DownloadReceipt(directory / f"{receipt_id}.json", account, asin, layout.root, update,
                                  legacy_paths=legacy_paths)
        if job.get("restart"):
            update("Restarting audio from the beginning", milestone="downloadRestarted")
        files, completed, groups = receipt.files, receipt.completed, receipt.groups
        warnings = []

        def call(command, **fields):
            if stop.is_set():
                raise InterruptedError("Transfer cancelled.")
            if command in {"download", "extras", "jsonExtras"}:
                with self.transfer_slot("download", settings, stop, update):
                    if self.demo:
                        return self.demo_download(command, book, folder, **fields)
                    self.refusals.check(account, lambda code: str(AudibleError(code)))
                    try:
                        return self.client.run(command, account_id=account, cancel=stop, **fields)
                    except AudibleError as error:
                        self.refusals.record(account, error.code, str(error))
                        raise
            return self.client.run(command, account_id=account, cancel=stop, **fields)

        def account_activation(refresh=False):
            if self.demo:
                return "00000000"
            old_session = self.client.session(account)
            result = self.client.run("activation", session=old_session, cancel=stop, options=api,
                                     refreshActivation=refresh)
            if result.get("session"):
                self.client.update_session(account, old_session, result["session"])
            return result.get("activationBytes", "")

        def download_sources(directory, download_api, detail):
            reserved = False
            try:
                with self.pacer.reserve(job["id"], plus=book.get("isAudiblePlus")) as record:
                    reserved = True
                    update(detail, 0, milestone="downloading")
                    protection = (
                        self.widevine_download_fields(account, download_api) if settings.get("prefer_widevine", True) else {}
                    )
                    result = call("download", asin=asin, directory=str(directory), options=download_api,
                                  progress=lambda fraction: update(detail, fraction),
                                  **protection)
                    parts = result.get("parts", [])
                    if not parts:
                        raise ValueError("Audible did not return an audio file.")
                    sources = [(staged_file(directory, part.get("file")), part.get("credentials") or {},
                                part.get("originalFilename")) for part in parts]
                    received = 0
                    for part, (source, _, _) in zip(parts, sources, strict=True):
                        count = part.get("downloadedBytes")
                        received += count if type(count) is int and count >= 0 else source.stat().st_size
                    record(received)
                    return sources
            finally:
                if reserved:
                    update(detail, milestone="pacingAvailable")

        save_file = partial(self._save_download_file, layout, book, files, stop)
        source_format = None
        saved_originals = [Path(path) for path in groups.get("audio", ())]
        if saved_originals:
            source_format = saved_originals[0].suffix.lstrip(".").casefold()

        saves_original = options.get("downloadAudio") and (not options.get("convert") or options.get("keepOriginal"))
        needs_original = saves_original and not saved_originals
        needs_conversion = options.get("downloadAudio") and options.get("convert") and "conversion" not in completed

        try:
            if needs_original or needs_conversion:
                archive_audio = saved_originals
                use_other_originals = not replacement and not options.get("repair")
                if not archive_audio and use_other_originals and settings["existing_files"] == "reuse":
                    archive_audio = self.archived_originals(account, asin, layout.root)
                matches = [Path(path) for path in job.get("matched_sources", ())] if use_other_originals else []
                if not archive_audio and matches and not all(path.is_file() for path in matches):
                    raise ValueError("One or more matched audio files are missing. Change the file match or reconnect the drive.")
                local = archive_audio or matches
                parts = [(path, {}, None) for path in local] if local else download_sources(folder, api, "Downloading audio")
                source_format = parts[0][0].suffix.lstrip(".").casefold()
                if needs_original:
                    originals = []
                    for number, (source, keys, original_name) in enumerate(parts, 1):
                        original = source
                        if not local or (matches and local == matches and settings["existing_files"] == "new"):
                            original = save_file(source, part_number=number if len(parts) > 1 else None, original_name=original_name)
                            if keys.get("contentKey") and keys.get("contentIV"):
                                self.client.save_session(voucher_reference(original), json.dumps(keys))
                        originals.append(original)
                    receipt.mark("audio", originals)
                if not local:
                    update("Audio downloaded", 1, files=files, milestone="downloadCompleted")
                if needs_conversion:
                    update("Preparing conversion", milestone="preparingConversion")
                    converted, cleanup = self._convert_download(
                        parts, archive_audio, layout, book, account, options, settings, api, folder, stop, update,
                        call=call, get_activation=account_activation, download_sources=download_sources,
                    )
                    receipt.cleanup.extend(cleanup)
                    receipt.mark("conversion", converted)
                    update("Conversion completed", 1, files=files, milestone="conversionCompleted")

            if receipt.cleanup and "conversion" in completed:
                for record in receipt.cleanup.copy():
                    if self.recycle_record(Path(record[0]), record[1]):
                        receipt.cleanup.remove(record)
                    else:
                        warnings.append("The MP3 was saved, but the archived AAX could not move to the Recycle Bin.")
                receipt.save()

            if options.get("downloadAudio") and options.get("convert") and not options.get("keepOriginal"):
                folder_format = settings["conversion"]["format"]
            else:
                if not source_format and not replacement and settings["existing_files"] == "reuse":
                    local = self.archived_originals(account, asin, layout.root)
                    local = local or [Path(path) for path in job.get("matched_sources", ()) if Path(path).is_file()]
                    if local:
                        source_format = local[0].suffix.lstrip(".").casefold()
                folder_format = source_format or "extras"
            warnings.extend(self._save_companions(
                book, options, api, folder, folder_format, receipt, save_file, call, update,
            ))
            if stop.is_set():
                raise InterruptedError("Transfer cancelled.")
            playback = options.get("open_after_saving", "off")
            group = None
            if playback == "original" and saves_original:
                group = "audio"
            elif playback == "converted" and options.get("downloadAudio") and options.get("convert"):
                group = "conversion"
            if group and (warning := self._open_saved_output(receipt, group)):
                warnings.append(warning)
            if not warnings:
                shutil.rmtree(folder)
            if not files and warnings:
                raise ValueError(" ".join(warnings))
            if self.completed_download is not None and options.get("downloadAudio"):
                self.completed_download(book, receipt)
            return files, warnings
        except Exception:
            update("Saved files", files=files)
            raise

    def _open_saved_output(self, receipt, group):
        marker = PLAYER_STEPS[group]
        if marker in receipt.completed:
            return None
        for path in map(Path, receipt.groups.get(group, ())):
            if path.suffix.lstrip(".").casefold() in AUDIO_FORMATS:
                try:
                    self._open_in_player(path)
                except OSError:
                    return f"The saved {'original' if group == 'audio' else 'converted audio'} could not open in your player."
                receipt.mark(marker)
                break
        return None

    @staticmethod
    def _open_in_player(path):
        if os.name == "nt":
            os.startfile(path)

    @staticmethod
    def _output_recipe(preferences):
        profile = ConversionOptions.read(preferences)
        recipe = asdict(profile)
        if profile.format != "mp3":
            recipe["mp3_bitrate_mode"] = "automatic"
        if profile.variable_mp3:
            recipe["bitrate"] = 0
        else:
            recipe["mp3_quality"] = 2
        if profile.chapter_mode == "separate":
            recipe.update(embed_chapters=False, audio_mode="encode")
        if not profile.can_copy_chapter_audio:
            recipe["copy_chapter_audio"] = False
        recipe["move_aax_to_trash"] = False
        return recipe

    def _convert_download(self, parts, archived, layout, book, account, options, settings, api, folder, stop, update,
                          *, call, get_activation, download_sources):
        preferences = settings["conversion"]
        needs_chapters = preferences.get("embed_chapters") or preferences.get("chapter_mode") == "separate"
        chapters = artwork = None
        if needs_chapters and len(parts) == 1:
            try:
                chapters = call("chapters", asin=book["asin"], options=api)
            except AudibleError:
                pass
        if preferences.get("embed_artwork") and book.get("coverURL"):
            try:
                result = call("extras", asin=book["asin"], directory=str(folder), options=dict(api, coverSizes=[]),
                              cover=True, coverURL=book["coverURL"])
                if covers := result.get("covers"):
                    artwork = staged_file(folder, covers[0])
            except AudibleError:
                pass

        def convert(sources, activation="", refresh=None):
            inputs = []
            for source, keys, _ in sources:
                revision = source_revision(source)
                suffix = source.suffix.casefold()
                if suffix == ".aaxc" and not keys:
                    keys = self.book_voucher(source, book, account, cancel=stop, options=api)
                inputs.append(MediaInput(
                    source, activation if suffix == ".aax" else "",
                    keys.get("contentKey", ""), keys.get("contentIV", ""), expected_revision=revision,
                ))
            return self._convert(inputs, layout, book, preferences, stop, update, chapters=chapters,
                                 artwork=artwork, refresh_activation=refresh)

        cleanup = []
        if (os.name == "nt" and not options.get("repair") and not options.get("keepOriginal") and preferences.get("move_aax_to_trash")
                and preferences.get("format") == "mp3"):
            cleanup = [[str(path), list(source_revision(path))] for path in archived if path.suffix.casefold() == ".aax"]
        has_aax = any(source.suffix.casefold() == ".aax" for source, _, _ in parts)
        try:
            with self.transfer_slot("conversion", settings, stop, update):
                activation = get_activation() if has_aax else ""
                refresh = (lambda: get_activation(refresh=True)) if has_aax else None
                return convert(parts, activation, refresh), cleanup
        except (ActivationRequired, AudibleError) as error:
            if (not has_aax or api.get("format") != "preferAAX" or not book.get("isDownloadable", True)
                    or (isinstance(error, AudibleError) and error.code != "activation")):
                raise
        fallback = folder / "Conversion Source"
        fallback.mkdir(exist_ok=True)
        if is_reparse(fallback):
            raise ValueError("The conversion source folder is a link.")
        alternative = download_sources(fallback, dict(api, format="aaxcOnly"), "Downloading an AAXC copy for conversion")
        update("Audio downloaded", milestone="downloadCompleted")
        update("Preparing conversion", milestone="preparingConversion")
        with self.transfer_slot("conversion", settings, stop, update):
            return convert(alternative), []

    def _save_download_file(self, layout, book, files, stop, source, **naming):
        if stop.is_set():
            raise InterruptedError("Transfer cancelled.")
        format_name = source.suffix.lstrip(".").lower()
        with self.output_lock:
            destination = layout.destination(book, format_name, occupied=[*files, *self.reserved_outputs], **naming)
            copy_atomic(source, destination)
        return destination

    @staticmethod
    def _save_companions(book, options, api, folder, folder_format, receipt, save_file, call, update):
        warnings = []
        cover_sizes = api.get("coverSizes") or []
        missing_sizes = [size for size in cover_sizes if f"cover-{size}" not in receipt.completed]
        need_cover = options.get("downloadCover") and (bool(missing_sizes) if cover_sizes else "cover" not in receipt.completed)
        requests = [
            ("extras", {"cover": need_cover, "pdf": options.get("downloadPDF") and book.get("hasPDF", True)}),
            ("jsonExtras", {"chapters": options.get("downloadChapters"), "annotations": options.get("downloadAnnotations")}),
        ]
        names = {
            "pdf": ("Companion PDF", ""),
            "chapters": ("Chapters", " - Chapters"),
            "annotations": ("Notes", " - Notes"),
        }
        for command, requested in requests:
            missing = {name: enabled and name not in receipt.completed for name, enabled in requested.items()}
            if not any(missing.values()):
                continue
            update("Downloading companion files" if command == "extras" else "Saving chapter or annotation data")
            fields, request_options = {}, api
            if command == "extras":
                fields = {"coverURL": book.get("coverURL"), "coverImages": book.get("coverImages")}
                request_options = dict(api, coverSizes=missing_sizes)
            try:
                result = call(command, asin=book["asin"], directory=str(folder), options=request_options, **missing, **fields)
            except AudibleError as error:
                warnings.append(str(error))
                continue
            if missing.pop("cover", False):
                for filename in result.get("covers", ()):
                    try:
                        source = staged_file(folder, filename)
                        identifier = source.stem
                        if identifier in receipt.completed:
                            continue
                        size = identifier.removeprefix("cover-") if identifier.startswith("cover-") else ""
                        suffix = f" - Cover {size}" if size.isdecimal() else ""
                        saved = save_file(source, folder_format=folder_format, name_suffix=suffix)
                    except InterruptedError:
                        raise
                    except (OSError, ValueError) as error:
                        warnings.append(f"Could not save cover art. {error}")
                        continue
                    receipt.mark(identifier, [saved])
                    update("Cover saved", files=receipt.files, milestone="downloadCompleted")
                expected = {f"cover-{size}" for size in missing_sizes} if cover_sizes else {"cover"}
                if expected - receipt.completed:
                    warnings.append("Some requested cover art was unavailable.")
            for name, enabled in missing.items():
                if not enabled:
                    continue
                label, suffix = names[name]
                if not result.get(name):
                    warnings.append(f"{label} unavailable.")
                    continue
                try:
                    source = staged_file(folder, result[name])
                    saved = save_file(source, folder_format=folder_format, name_suffix=suffix)
                except InterruptedError:
                    raise
                except (OSError, ValueError) as error:
                    warnings.append(f"Could not save {label.lower()}. {error}")
                    continue
                receipt.mark(name, [saved])
                update(f"{label} saved", files=receipt.files, milestone="downloadCompleted")
        return warnings

    def _convert(self, sources, layout, book, options, stop, update, **kwargs):
        reserved = []

        def destinations(specs):
            with self.output_lock:
                paths = [
                    self._reserve(layout, book, spec, reserved)
                    for spec in specs
                ]
            return paths

        try:
            return self.tools.convert(
                sources, layout.root, options, metadata=book, destinations=destinations,
                progress=lambda fraction: update("Converting audio", fraction), cancel=stop, **kwargs,
            )
        finally:
            with self.output_lock:
                for path in reserved:
                    self.reserved_outputs.discard(path)

    def _reserve(self, layout, book, specification, reserved):
        path = layout.destination(book, specification.format, specification.chapter_number,
                                  specification.chapter_title, occupied=self.reserved_outputs,
                                  edited=specification.edited, name_suffix=specification.name_suffix)
        self.reserved_outputs.add(path)
        reserved.append(path)
        return path

    def archived_originals(self, account, asin, root):
        records = (self.data_dir / "Receipts").glob("*.json")
        for record in records:
            try:
                saved = read_json(record) or {}
                if (saved.get("account_id"), saved.get("asin"), saved.get("root")) != (account, asin, str(root)):
                    continue
                paths = [Path(path) for path in saved.get("groups", {}).get("audio", [])]
                sizes = saved.get("sizes", {})
                if paths and all(path.resolve().is_relative_to(root.resolve()) and recorded_file(path, sizes) for path in paths):
                    return paths
            except (OSError, ValueError):
                continue
        return []

    def book_voucher(self, path, book, account, *, cancel, options):
        reference = voucher_reference(path)
        if not self.demo and self.client.has_session(reference):
            return json.loads(self.client.session(reference))
        if adjacent := read_voucher(path):
            return {"contentKey": adjacent[0], "contentIV": adjacent[1]}
        if account and re.fullmatch("[A-Z0-9]{10}", book.get("asin") or "", flags=re.IGNORECASE):
            return self.client.run("voucher", account_id=account, cancel=cancel, options=options, asin=book["asin"])
        return {}

    @staticmethod
    def recycle_record(path, revision):
        try:
            stat = path.stat()
        except FileNotFoundError:
            return True
        except OSError:
            return False
        return file_revision(stat) == revision and recycle_source(path, stat)

    def convert_local(self, job, settings, stop, update):
        source = Path(job["source"])
        sources = [Path(value) for value in job.get("sources", [str(source)])]
        options = dict(settings["conversion"], **job.get("options", {}))
        receipt = self.data_dir / "Conversion Results" / f"{job['id']}.json"
        saved = read_json(receipt) or {}
        previous = [Path(file) for file in saved.get("files", [])]
        if previous and all(path.is_file() for path in previous):
            return previous, self.retry_cleanup(receipt, previous, saved.get("cleanup", []))
        revisions = job.get("source_revisions", job.get("revisions", {}))
        source_stats = {}
        for path in sources:
            if not path.is_file():
                raise ValueError("The source file could not be found.")
            revision = revisions.get(str(path)) or (job.get("revision") if path == source else None)
            stat = path.stat()
            source_stats[path] = stat
            if revision and revision not in (file_revision(stat), [stat.st_size, stat.st_mtime_ns]):
                raise ValueError("The source file changed after this edit was prepared.")
        book = dict(job.get("book") or {})
        if not book:
            scanned = self.tools.scan(source, cancel=stop)
            if scanned:
                item = scanned[0]
                book.update(item.metadata)
                book["title"] = item.title
                if item.author:
                    book["author"] = item.author
                if item.asin:
                    book["asin"] = item.asin
            else:
                book["title"] = source.stem
        book.update(job.get("metadata") or {})
        account = job.get("account_id")
        def activation(refresh=False):
            if account:
                session = self.client.session(account)
                result = self.client.run("activation", session=session, cancel=stop,
                                         options=api_options(settings), refreshActivation=refresh)
                if not self.demo and result.get("session"):
                    self.client.update_session(account, session, result["session"])
                return result.get("activationBytes", "")
            return ""

        manual_code = self._job_code(job)
        inputs = []
        for path in sources:
            credentials = {}
            source_type = path.suffix.casefold()
            if source_type == ".aax":
                credentials["activation_bytes"] = manual_code or activation()
            elif source_type == ".aaxc":
                voucher = self.book_voucher(path, book, account, cancel=stop, options=api_options(settings))
                credentials.update(audible_key=voucher.get("contentKey", ""), audible_iv=voucher.get("contentIV", ""))
            inputs.append(MediaInput(path, expected_revision=tuple(file_revision(source_stats[path])), **credentials))
        edit = {
            "chapters": job.get("chapters"), "excluded_sections": job.get("excluded_sections", ()),
            "expected_sections": job.get("expected_sections"),
            "chapter_repair": job.get("chapter_repair"),
            "refresh_activation": (lambda: activation(True)) if account and not manual_code else None,
        }
        with self.transfer_slot("conversion", settings, stop, update):
            if job.get("destination"):
                paths = self.tools.convert(inputs, Path(job["destination"]), options, metadata=book,
                                           progress=lambda fraction: update("Converting audio", fraction), cancel=stop, **edit)
            else:
                paths = self._convert(inputs, ArchiveLayout.from_settings(settings), book, options, stop, update, **edit)
        cleanup = []
        if (job["kind"] == "Conversion" and options.get("move_aax_to_trash") and options.get("format") == "mp3"
                and os.name == "nt"):
            cleanup = [[str(path), file_revision(source_stats[path])] for path in sources if path.suffix.casefold() == ".aax"]
        if cleanup:
            write_json(receipt, {"files": [str(path) for path in paths], "cleanup": cleanup})
        warnings = self.retry_cleanup(receipt, paths, cleanup)
        update("Conversion completed", 1, files=paths, milestone="conversionCompleted")
        return paths, warnings

    def retry_cleanup(self, receipt, paths, cleanup):
        pending = [item for item in cleanup if not self.recycle_record(Path(item[0]), item[1])]
        if cleanup:
            write_json(receipt, {"files": [str(path) for path in paths], "cleanup": pending})
        return ["The converted audio was saved, but the original could not move to the Recycle Bin."] if pending else []

    def demo_download(self, command, book, folder, **fields):
        if command == "download":
            progress = fields.get("progress") or (lambda value: None)
            progress(0.25)
            source = folder / f"{book['asin']}.m4a"
            if not source.exists():
                demo_audio(self.tools.ffmpeg, source, book["title"], book["asin"])
            progress(1.0)
            return {"parts": [{"file": source.name, "asin": book["asin"], "credentials": {}}]}
        if command == "jsonExtras":
            result = {"failed": {}}
            for name in ("chapters", "annotations"):
                if fields.get(name):
                    path = folder / f"{name}.json"
                    write_json(path, {"asin": book["asin"], name: []})
                    result[name] = path.name
            return result
        result = {"covers": [], "failed": {}}
        if fields.get("cover"):
            from PIL import Image
            for size in fields["options"].get("coverSizes") or [None]:
                path = folder / (f"cover-{size}.png" if size else "cover.png")
                Image.new("RGB", (size or 256, size or 256), (73, 97, 150)).save(path)
                result["covers"].append(path.name)
        if fields.get("pdf"):
            from PIL import Image
            path = folder / "companion.pdf"
            Image.new("RGB", (320, 240), (245, 245, 245)).save(path)
            result["pdf"] = path.name
        return result

    def _job_code(self, job):
        reference = job.get("activation_reference")
        if reference:
            return self.client.session(reference) or ""
        return ""

    @contextmanager
    def retry_activation_reference(self, activation_bytes):
        if not activation_bytes:
            yield None
            return
        reference = "activation-" + uuid4().hex
        with self.client.session_change(reference, activation_bytes):
            yield reference


def demo_audio(ffmpeg, path, title="Demo Audiobook", asin="DEMO000003"):
    from array import array
    from math import pi, sin

    path.parent.mkdir(parents=True, exist_ok=True)
    source = path.with_suffix(".wav")
    sample_rate = 22050
    tone = array("h", (int(1800 * sin(index * 2 * pi * 440 / sample_rate)) for index in range(sample_rate)))
    with wave.open(str(source), "wb") as stream:
        stream.setparams((1, 2, sample_rate, 0, "NONE", "Uncompressed"))
        stream.writeframes(tone.tobytes() * 4)
    metadata = path.with_suffix(".ffmeta")
    metadata.write_text(f";FFMETADATA1\ntitle={title}\nartist=Demo Author 2\nASIN={asin}\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Opening Credits\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=3000\ntitle=Chapter 1\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=3000\nEND=4000\ntitle=End Credits\n",
                        encoding="utf-8")
    try:
        subprocess.run([str(ffmpeg), "-nostdin", "-v", "error", "-y", "-i", str(source), "-i", str(metadata),
                        "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-c:a", "aac",
                        "-movflags", "use_metadata_tags", str(path)], capture_output=True, check=True,
                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.stderr.decode("utf-8", errors="replace")) from error
    finally:
        source.unlink(missing_ok=True)
        metadata.unlink(missing_ok=True)
    return path

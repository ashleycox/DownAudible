"""Persistent, cancellable download and conversion batches."""

import json
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
from copy import deepcopy
from datetime import UTC, datetime
from math import isfinite
from pathlib import Path
from stat import FILE_ATTRIBUTE_REPARSE_POINT, S_ISREG
from threading import Event, RLock, Timer
from time import monotonic, time
from uuid import uuid4

from .pacing import DownloadDeferred
from .refusal import RetryAfter
from .state import write_json

RETRYABLE = {"Failed", "Cancelled", "Interrupted", "Stopped", "Warning"}
ACTIVE = {"Running", "Waiting"}
STATUSES = RETRYABLE | ACTIVE | {"Completed"}
KINDS = {"Download", "Conversion", "Edit"}
HISTORY_LIMIT = 10


def accepts_activation_bytes(job):
    if job["kind"] not in {"Conversion", "Edit"}:
        return False
    sources = job.get("sources") or (job.get("source"),)
    return any(isinstance(path, str) and Path(path).suffix.casefold() == ".aax" for path in sources)


def finite_json_number(value):
    number = float(value)
    if not isfinite(number):
        raise ValueError("The transfer queue contains a non-finite number.")
    return number


def validate_saved_queue(state):
    if not isinstance(state, dict) or "current" not in state or not isinstance(state.get("history"), list):
        raise ValueError("The transfer queue has an invalid format.")
    batches = state["history"] if state["current"] is None else [state["current"], *state["history"]]
    batch_ids, job_ids = set(), set()
    for batch in batches:
        if not isinstance(batch, dict) or not isinstance(batch.get("jobs"), list) or not isinstance(batch.get("settings"), dict):
            raise TypeError("A saved batch has invalid jobs or settings.")
        identifier = batch.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in batch_ids:
            raise ValueError("A saved batch has an invalid or duplicate identifier.")
        batch_ids.add(identifier)
        if not isinstance(batch.get("date"), str):
            raise TypeError("A saved batch is missing its date.")
        datetime.fromisoformat(batch["date"]).astimezone()
        for name in ("download_limit", "conversion_limit"):
            if name in batch["settings"]:
                limit = batch["settings"][name]
                if type(limit) is not int or not 1 <= limit <= 12:
                    raise ValueError("A saved batch has an invalid transfer limit.")
        for job in batch["jobs"]:
            validate_saved_job(job, job_ids)


def validate_saved_job(job, job_ids):
    if not isinstance(job, dict):
        raise TypeError("A saved transfer has an invalid format.")
    identifier, status, kind = (job.get(key) for key in ("id", "status", "kind"))
    if not isinstance(identifier, str) or not identifier or identifier in job_ids:
        raise ValueError("A saved transfer has an invalid or duplicate identifier.")
    job_ids.add(identifier)
    if not isinstance(status, str) or status not in STATUSES or not isinstance(kind, str) or kind not in KINDS:
        raise ValueError("A saved transfer has an invalid status or kind.")
    if not isinstance(job.get("title"), str) or not isinstance(job.get("detail"), str):
        raise TypeError("A saved transfer is missing its title or status details.")
    files, progress = job.get("files"), job.get("progress")
    if not isinstance(files, list) or not all(isinstance(path, str) for path in files):
        raise ValueError("A saved transfer has invalid output paths.")
    if progress is not None and (type(progress) not in (int, float) or not isfinite(progress)):
        raise ValueError("A saved transfer has invalid progress.")
    if "local_settings" in job and (kind == "Download" or not isinstance(job["local_settings"], dict)):
        raise TypeError("A saved local transfer has invalid settings.")
    if "refusal_until" in job:
        if type(job["refusal_until"]) not in (int, float) or not isfinite(job["refusal_until"]):
            raise ValueError("A saved transfer has an invalid retry time.")
        datetime.fromtimestamp(job["refusal_until"])
    if "refusal_attempts" in job and (type(job["refusal_attempts"]) is not int or not 0 <= job["refusal_attempts"] <= 2):
        raise ValueError("A saved transfer has an invalid retry count.")
    if kind == "Download":
        book = job.get("book")
        if not isinstance(book, dict) or not isinstance(book.get("asin"), str) or not book["asin"]:
            raise ValueError("A saved download is missing its audiobook identifier.")
        if not isinstance(job.get("options"), dict):
            raise ValueError("A saved download has invalid options.")


def interrupt_jobs(batch):
    if batch:
        for job in batch["jobs"]:
            if job["status"] in ACTIVE:
                detail = job["detail"] if "refusal_until" in job else "Retry to resume this job."
                job.update(status="Interrupted", detail=detail, progress=None)
                job.pop("pacing_until", None)
                job.pop("pacing_inflight", None)


class BatchQueue:
    def __init__(self, path: Path, execute, changed, finished, *, has_partial=None, clock=time, timer=Timer):
        self.path, self.execute, self.changed, self.finished = path, execute, changed, finished
        self.has_partial = has_partial
        self.lock = RLock()
        self.workers = ThreadPoolExecutor(max_workers=24, thread_name_prefix="DownAudible")
        self.running: dict[str, Event] = {}
        self.progress_clock = {}
        self.closing = False
        self.cancelled_batch = False
        self.run_finished_work = False
        self.events = {}
        self.persistence_error = None
        self.recovery_warning = None
        self._recovery_path = None
        self.clock, self.timer = clock, timer
        self._pacing_timer = None
        self._pacing_generation = 0
        self.state = self._load()

    def _load(self):
        try:
            with self.path.open(encoding="utf-8") as stream:
                saved = json.load(stream, parse_float=finite_json_number, parse_constant=finite_json_number)
            validate_saved_queue(saved)
        except FileNotFoundError:
            return {"current": None, "history": []}
        except (OSError, TypeError, ValueError, OverflowError, RecursionError) as error:
            self._recovery_path = self.path.with_name(f"{self.path.stem}.unreadable-{uuid4().hex}{self.path.suffix}")
            warning = f"DownAudible could not read the saved transfer queue and opened an empty queue.\n\n{error}"
            try:
                recovery_path = self._preserve_unreadable_queue()
            except OSError:
                self.recovery_warning = (f"{warning}\n\nThe original queue is still at {self.path}. "
                                         "DownAudible will preserve it before saving new transfers.")
            else:
                self.recovery_warning = f"{warning}\n\nThe original queue was kept at {recovery_path}." if recovery_path else warning
            return {"current": None, "history": []}
        for batch in (saved["current"], *saved["history"]):
            interrupt_jobs(batch)
        return saved

    def _preserve_unreadable_queue(self):
        backup = self._recovery_path
        if self.path.is_dir():
            raise IsADirectoryError(f"A directory occupies the queue path at {self.path}.")
        try:
            self.path.rename(backup)
        except FileNotFoundError:
            backup = None
        self._recovery_path = None
        return backup

    def snapshot(self):
        with self.lock:
            return deepcopy(self.state)

    def save(self):
        with self.lock:
            self._write_state(self.state)

    def _write_state(self, state):
        if self._recovery_path is not None:
            self._preserve_unreadable_queue()
        write_json(self.path, state)
        self.persistence_error = None

    def _publish(self):
        if not self.closing:
            try:
                self.save()
            except OSError as error:
                self.persistence_error = str(error)
        self.changed()

    @property
    def active(self):
        with self.lock:
            return bool(self.running)

    @property
    def pending(self):
        with self.lock:
            current = self.state["current"]
            return bool(self.running) or bool(current and any(job["status"] == "Waiting" for job in current["jobs"]))

    def download_addition_state(self, account):
        with self.lock:
            batch = self.state["current"]
            if not self.pending or self.closing or self.cancelled_batch or not batch or not account:
                return None
            first = batch["jobs"][0]
            if first["kind"] != "Download" or first.get("account_id") != account or first["options"].get("repair"):
                return None
            if not batch["settings"].get("continue_after_error", True) and (
                self.events.get("downloadFailed") or self.events.get("conversionFailed")
            ):
                return None
            return batch["id"], {job["book"]["asin"] for job in batch["jobs"]
                                  if job["kind"] == "Download" and job.get("account_id") == account}

    def submit(self, jobs, settings, *, add=False, expected_batch=None):
        with self.lock:
            if self.closing:
                raise RuntimeError("DownAudible is closing.")
            if not jobs:
                return 0
            previous = deepcopy(self.state)
            current = self.state["current"]
            extending = self.pending
            adding_local = (extending and not self.running and any(
                job["status"] == "Waiting" and ("pacing_until" in job or "refusal_until" in job) for job in current["jobs"])
                            and all(job["kind"] in {"Conversion", "Edit"} for job in jobs))
            if expected_batch is not None and (not extending or current["id"] != expected_batch):
                raise ValueError("The running batch changed or finished. Review the titles and try again.")
            if adding_local:
                jobs = [dict(job, local_settings=deepcopy(settings)) for job in jobs]
            elif extending:
                if not add:
                    raise ValueError("Wait for the current batch, or add these books to its queue.")
                if self.cancelled_batch:
                    raise ValueError("Wait for the cancelled batch to stop before adding downloads.")
                current_jobs = current["jobs"]
                account = jobs[0].get("account_id")
                state = self.download_addition_state(account)
                if state is None or any(job.get("account_id") != account or job["kind"] != "Download" for job in jobs):
                    raise ValueError("Only an active download batch that accepts more books can take downloads from the same account.")
                _, existing = state
                options = current_jobs[0]["options"]
                additions = []
                for job in jobs:
                    asin = job["book"]["asin"]
                    if asin not in existing:
                        additions.append(dict(job, options=deepcopy(options)))
                        existing.add(asin)
                jobs = additions
            if not jobs:
                return 0
            if not extending:
                if current and current["jobs"]:
                    self.state["history"].insert(0, current)
                    del self.state["history"][HISTORY_LIMIT:]
                current = {
                    "id": str(uuid4()),
                    "date": datetime.now(UTC).isoformat(),
                    "jobs": [],
                    "settings": deepcopy(settings),
                }
                self.state["current"] = current
            current["jobs"].extend(
                dict(job, id=str(uuid4()), status="Waiting", detail="", progress=None, files=[],
                     replacement_id=str(uuid4()) if job.get("restart") else None)
                for job in jobs
            )
            self._save_or_restore(previous)
            if not extending:
                self.cancelled_batch = False
                self.run_finished_work = False
                self.events.clear()
            self._dispatch()
            self.changed()
            return len(jobs)

    def _save_or_restore(self, previous):
        try:
            self.save()
        except (OSError, TypeError, ValueError):
            self.state = previous
            raise

    def _dispatch(self, *, released=False):
        batch = self.state["current"]
        if self.closing or self.cancelled_batch or not batch:
            self._schedule_pacing(None)
            return
        jobs = batch["jobs"]
        settings = batch["settings"]
        now = self.clock()
        wake_at = None
        downloads = sum(job["status"] == "Running" and job.get("phase", "download") == "download" for job in jobs)
        conversions = len(self.running) - downloads
        for job in jobs:
            if job["status"] != "Waiting":
                continue
            retry = job.get("refusal_until")
            if retry is not None and retry > now:
                wake_at = retry if wake_at is None else min(wake_at, retry)
                continue
            job.pop("refusal_until", None)
            until = job.get("pacing_until")
            if until is not None:
                if until > now and not (released and job.get("pacing_inflight")):
                    wake_at = until if wake_at is None else min(wake_at, until)
                    continue
                self._clear_pacing(job)
                job["detail"] = "Waiting for an available download slot."
            if job["kind"] == "Download":
                if downloads >= settings.get("download_limit", 3):
                    continue
                downloads += 1
            else:
                if conversions >= settings.get("conversion_limit", 2):
                    continue
                conversions += 1
            identifier = job["id"]
            stop = self.running[identifier] = Event()
            job.update(status="Running", detail="Preparing", progress=None,
                       phase="download" if job["kind"] == "Download" else "conversion")
            self.workers.submit(self._work, batch["id"], deepcopy(job), deepcopy(job.get("local_settings", settings)),
                                stop, self._pacing_generation)
        self._schedule_pacing(wake_at)

    @staticmethod
    def _clear_pacing(job):
        job.pop("pacing_until", None)
        job.pop("pacing_inflight", None)

    def _schedule_pacing(self, wake_at):
        if self._pacing_timer is not None:
            self._pacing_timer.cancel()
            self._pacing_timer = None
        if wake_at is None:
            return
        # Check UTC periodically in case the computer sleeps or its wall clock changes.
        delay = max(0.2, min(60, wake_at - self.clock()))

        def wake():
            with self.lock:
                if self._pacing_timer is not timer:
                    return
                self._pacing_timer = None
                self._dispatch()
                self._publish()

        timer = self.timer(delay, wake)
        timer.daemon = True
        self._pacing_timer = timer
        timer.start()

    def pacing_changed(self):
        with self.lock:
            self._pacing_generation += 1
            batch = self.state["current"]
            if not batch or not any("pacing_until" in job for job in batch["jobs"]):
                return
            for job in batch["jobs"]:
                self._clear_pacing(job)
            self._dispatch()
            self._publish()

    def _work(self, batch_id, job, settings, stop, pacing_generation):
        identifier = job["id"]
        stage = "download" if job["kind"] == "Download" else "conversion"

        def update(detail, fraction=None, *, files=None, milestone=None):
            nonlocal stage
            with self.lock:
                if milestone == "pacingAvailable":
                    self._dispatch(released=True)
                    return
                if milestone in {"downloadCompleted", "conversionCompleted"}:
                    self.events.setdefault(milestone, set()).add(identifier)
                active = self._find(identifier)
                if active and milestone == "downloadRestarted":
                    active["restart"] = False
                    self._publish()
                if milestone == "preparingConversion":
                    stage = "conversion"
                elif milestone == "downloading":
                    stage = "download"
                if active and milestone == "preparingConversion" and active.get("phase") == "download":
                    active["phase"] = "conversion"
                    self._dispatch()
                now = monotonic()
                if active and (active["detail"] != detail or files is not None
                               or now - self.progress_clock.get(identifier, 0) >= 0.2):
                    self.progress_clock[identifier] = now
                    active.update(detail=detail, progress=fraction)
                    if files is not None:
                        active["files"] = [str(file) for file in files]
                    self.changed()

        deferred = None
        refusal = None
        try:
            files, warnings = self.execute(job, settings, stop, update)
            status = "Warning" if warnings else "Completed"
            detail = "; ".join(warnings) if warnings else "Saved"
        except DownloadDeferred as error:
            deferred = error
            files = None
            status = "Waiting"
            if error.until is None:
                detail = "Waiting for an active audio download to finish."
            else:
                resumes = datetime.fromtimestamp(error.until).astimezone()
                detail = f"Daily limit reached. Resumes {resumes:%d %b %Y at %H:%M}."
        except RetryAfter as error:
            refusal = error
            files = None
            status = "Failed" if error.new and job.get("refusal_attempts", 0) >= 1 else "Waiting"
            detail = error.detail(automatic=status == "Waiting")
        except Exception as error:  # noqa: BLE001 - a worker must publish a failed result before releasing its slot
            files = None
            status = "Cancelled" if stop.is_set() else "Failed"
            detail = "Retry to resume this job." if stop.is_set() else str(error) or type(error).__name__
        with self.lock:
            active = self._find(identifier)
            self.running.pop(identifier, None)
            self.progress_clock.pop(identifier, None)
            if active is None:
                return
            if deferred is not None and stop.is_set():
                deferred = None
                status = "Cancelled"
                detail = "Retry to resume this job."
            if refusal is not None and stop.is_set():
                refusal = None
                status = "Cancelled"
                detail = "Retry to resume this job."
            if self.closing and status == "Cancelled":
                status = "Interrupted"
            if status in {"Completed", "Warning", "Failed"}:
                self.run_finished_work = True
            active.update(status=status, detail=detail, progress=None)
            if deferred is not None and pacing_generation != self._pacing_generation:
                active["detail"] = "Checking the updated daily download limit."
            elif deferred is not None:
                active["pacing_until"] = deferred.until if deferred.until is not None else self.clock() + 1
                active["pacing_inflight"] = deferred.until is None
            if refusal is not None:
                active["refusal_until"] = refusal.until
                if refusal.new:
                    active["refusal_attempts"] = min(2, active.get("refusal_attempts", 0) + 1)
            if files is not None:
                active["files"] = [str(file) for file in files]
            discard = ()
            if status in {"Cancelled", "Interrupted"}:
                discard = ("downloadCompleted", "conversionCompleted")
            elif status == "Failed":
                discard = (f"{stage}Completed",)
            for event in discard:
                if identifiers := self.events.get(event):
                    identifiers.discard(identifier)
                    if not identifiers:
                        del self.events[event]
            if status == "Failed":
                self.events.setdefault(f"{stage}Failed", set()).add(identifier)
                if not settings.get("continue_after_error", True):
                    for waiting in self.state["current"]["jobs"]:
                        if waiting["status"] == "Waiting":
                            self._clear_pacing(waiting)
                            waiting.update(status="Stopped", detail="An earlier job failed.")
            self._write_log(active, settings)
            self._dispatch()
            self._publish()
            if not self.pending and not self.cancelled_batch and not self.closing:
                if self.run_finished_work:
                    self.finished(batch_id, deepcopy(self.events), deepcopy(self.state["current"]["settings"]))
                self.events.clear()

    def _find(self, identifier):
        current = self.state["current"]
        if current:
            return next((job for job in current["jobs"] if job["id"] == identifier), None)
        return None

    def _write_log(self, job, settings):
        level = settings.get("log_level", "off")
        status = job["status"]
        if level == "off" or status not in {"Completed", "Failed", "Warning"} or (level == "errors" and status == "Completed"):
            return
        custom = settings.get("log_file")
        path = Path(custom) if custom else self.path.with_name("Transfers.log")
        try:
            if not custom:
                path.parent.mkdir(parents=True, exist_ok=True)
            try:
                entry = path.lstat()
            except FileNotFoundError:
                pass
            else:
                if not S_ISREG(entry.st_mode) or getattr(entry, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT:
                    raise OSError("The transfer log path needs to be a regular file.")
            with path.open("a", encoding="utf-8") as stream:
                fields = [datetime.now().astimezone().isoformat(timespec="seconds"),
                          job["title"], job["status"], job["detail"]]
                stream.write("\t".join(" ".join(field.split()) for field in fields) + "\n")
        except OSError:
            warning = "The transfer log could not be written."
            if status == "Completed":
                job.update(status="Warning", detail=f"Saved. {warning}")
            else:
                job["detail"] = f"{job['detail']} {warning}"

    def cancel(self, identifiers=None, *, closing=False):
        with self.lock:
            current = self.state["current"]
            self.closing |= closing
            self.cancelled_batch |= identifiers is None
            if current:
                for job in current["jobs"]:
                    identifier = job["id"]
                    if identifiers is not None and identifier not in identifiers:
                        continue
                    if identifier in self.running:
                        self.running[identifier].set()
                    elif job["status"] == "Waiting":
                        self._clear_pacing(job)
                        job.update(status="Interrupted" if self.closing else "Cancelled",
                                   detail=job["detail"] if "refusal_until" in job else "Retry to resume this job.")
            self._dispatch()
            self._publish()

    def prepare_close(self, *, save=True):
        with self.lock:
            if save:
                snapshot = deepcopy(self.state)
                interrupt_jobs(snapshot["current"])
                self._write_state(snapshot)
            self.cancel(closing=True)

    def reopen(self):
        with self.lock:
            self.closing = False
            self.changed()

    def retry(self, batch_id, identifiers=None, *, restart=False, prepare_activation=None):
        with self.lock:
            if self.closing:
                raise RuntimeError("DownAudible is closing.")
            if self.pending:
                raise ValueError("Wait for the current batch to finish.")
            current = self.state["current"]
            batch = next((batch for batch in [current, *self.state["history"]]
                          if batch and batch["id"] == batch_id), None)
            if batch is None:
                return 0
            jobs = [
                job for job in batch["jobs"]
                if (identifiers is None or job["id"] in identifiers)
                and job["status"] in RETRYABLE
                and (not restart or (
                    job["kind"] == "Download" and (self.has_partial is None or self.has_partial(job, batch["settings"]))
                ))
            ]
            if not jobs:
                return 0
            activation_jobs = [job for job in jobs if accepts_activation_bytes(job)] if prepare_activation else []
            with prepare_activation() if activation_jobs else nullcontext() as reference:
                previous = deepcopy(self.state)
                if batch is not current:
                    self.state["history"].remove(batch)
                    if current and current["jobs"]:
                        self.state["history"].insert(0, current)
                    self.state["current"] = batch
                for job in jobs:
                    self._clear_pacing(job)
                    job.pop("refusal_attempts", None)
                    job.update(status="Waiting", detail=job["detail"] if "refusal_until" in job else "", progress=None)
                    if restart:
                        job.update(restart=True, replacement_id=str(uuid4()))
                for job in activation_jobs:
                    if reference is None:
                        job.pop("activation_reference", None)
                    else:
                        job["activation_reference"] = reference
                self._save_or_restore(previous)
            self.cancelled_batch = False
            self.run_finished_work = False
            self.events.clear()
            self._dispatch()
            self.changed()
            return len(jobs)

    def remove(self, identifiers=None, *, completed_only=False, batch_id=None):
        with self.lock:
            if self.closing:
                raise RuntimeError("DownAudible is closing.")
            current = self.state["current"]
            if batch_id is None or (current and current["id"] == batch_id):
                batch = current
            else:
                batch = next((item for item in self.state["history"] if item["id"] == batch_id), None)
            if batch is None:
                return
            if batch is current and self.pending:
                raise ValueError("Wait for the current batch to finish.")
            remaining = [
                job for job in batch["jobs"] if not (
                    (identifiers is None or job["id"] in identifiers)
                    and (not completed_only or job["status"] == "Completed")
                )
            ]
            if len(remaining) == len(batch["jobs"]):
                return
            previous = deepcopy(self.state)
            batch["jobs"] = remaining
            if batch is not current and not remaining:
                self.state["history"].remove(batch)
            self._save_or_restore(previous)
            if batch is current:
                self._dispatch()
            self.changed()

    def close(self):
        with self.lock:
            self.closing = True
            self._schedule_pacing(None)
        self.workers.shutdown(wait=False, cancel_futures=False)

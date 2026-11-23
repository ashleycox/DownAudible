"""Queue regression checks exercised without a desktop or network."""

import sys
from contextlib import nullcontext
from functools import partial
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event
from unittest import TestCase
from unittest.mock import Mock, patch

from downaudible_windows.audible import AudibleClient
from downaudible_windows.jobs import JobRunner
from downaudible_windows.pacing import DownloadDeferred
from downaudible_windows.queue import BatchQueue
from downaudible_windows.state import read_json, write_json

SETTINGS = {"download_limit": 1, "conversion_limit": 1, "continue_after_error": True}
DATE = "2026-11-23T00:00:00+00:00"


def request(asin, account="example"):
    return {"kind": "Download", "title": asin, "book": {"asin": asin}, "account_id": account, "options": {}}


def failed_job(identifier, kind, **fields):
    return dict(id=identifier, kind=kind, title=identifier, status="Failed",
                detail="Synthetic failure", progress=None, files=[], **fields)


def fixture_activation_vault():
    if sys.platform == "win32":
        return nullcontext()
    return patch("downaudible_windows.audible._dpapi", side_effect=lambda contents, **options: contents[::-1])


class BatchQueueTests(TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.path = self.folder / "Queue.json"
        self.started = Event()
        self.convert = Event()
        self.release = Event()
        self.finished = Event()
        self.second = Event()

    def create(self, run, **options):
        queue = BatchQueue(self.path, run, lambda: None, lambda *args: self.finished.set(), **options)
        self.addCleanup(queue.workers.shutdown)
        self.addCleanup(self.release.set)
        self.addCleanup(self.convert.set)
        return queue

    def test_download_slot_becomes_available_while_the_first_title_converts(self):
        def run(job, settings, cancelled, update):
            if job["title"] == "DEMO000001":
                self.started.set()
                self.assertTrue(self.convert.wait(5))
                update("Converting audio", milestone="preparingConversion")
                self.assertTrue(self.release.wait(5))
            else:
                self.second.set()
            return [], []

        queue = self.create(run)
        self.assertEqual(queue.submit([request("DEMO000001"), request("DEMO000002")], SETTINGS), 2)
        self.assertTrue(self.started.wait(5))
        self.assertFalse(self.second.is_set())
        self.convert.set()
        self.assertTrue(self.second.wait(5))
        self.release.set()
        self.assertTrue(self.finished.wait(5))
        self.assertEqual([job["status"] for job in read_json(self.path)["current"]["jobs"]],
                         ["Completed", "Completed"])

    def test_daily_wait_resumes_at_deadline_and_keeps_local_conversion_available(self):
        now = 100_000
        released_at = now + 10
        paced = Event()
        converted = Event()

        def changed():
            current = queue.snapshot()["current"]
            if current and current["jobs"][0].get("pacing_until"):
                paced.set()

        def run(job, settings, *args):
            if job["kind"] == "Download" and now < released_at:
                raise DownloadDeferred(released_at)
            if job["kind"] == "Conversion":
                self.assertEqual(settings["archive_root"], "Other destination")
                converted.set()
            return [], []

        timer = Mock(side_effect=lambda delay, wake: Mock(delay=delay, wake=wake))
        queue = BatchQueue(self.path, run, changed, lambda *args: self.finished.set(), clock=lambda: now, timer=timer)
        self.addCleanup(queue.workers.shutdown)
        queue.submit([request("DEMO000001")], SETTINGS)
        self.assertTrue(paced.wait(5))
        self.assertTrue(queue.pending)
        self.assertFalse(queue.active)
        self.assertFalse(self.finished.is_set())
        with self.assertRaisesRegex(ValueError, "Wait for the current batch"):
            queue.remove()
        queue.submit([{"kind": "Conversion", "title": "Local audio"}], dict(SETTINGS, archive_root="Other destination"))
        self.assertTrue(converted.wait(5))
        self.assertEqual(queue.download_addition_state("example")[1], {"DEMO000001"})
        self.assertFalse(self.finished.is_set())
        now = released_at
        queue._pacing_timer.wake()
        self.assertTrue(self.finished.wait(5))
        self.assertEqual([job["status"] for job in queue.snapshot()["current"]["jobs"]],
                         ["Completed", "Completed"])

    def test_cancelling_a_paced_batch_cancels_the_timer(self):
        attempt = Mock(side_effect=DownloadDeferred(200_000))
        scheduled = Event()

        def make_timer(delay, wake):
            return Mock(delay=delay, wake=wake, start=scheduled.set)

        queue = self.create(attempt, clock=lambda: 100_000, timer=make_timer)
        queue.submit([request("DEMO000001")], SETTINGS)
        self.assertTrue(scheduled.wait(5))
        previous = queue._pacing_timer
        queue.cancel()
        previous.cancel.assert_called_once()
        previous.wake()
        self.assertFalse(queue.pending)
        self.assertEqual(queue.snapshot()["current"]["jobs"][0]["status"], "Cancelled")
        attempt.assert_called_once()
        self.assertFalse(self.finished.is_set())

    def test_pacing_change_rechecks_a_worker_deferred_under_the_old_limit(self):
        def run(*args):
            if not self.started.is_set():
                self.started.set()
                self.assertTrue(self.release.wait(5))
                raise DownloadDeferred(200_000)
            return [], []

        queue = self.create(run, clock=lambda: 100_000)
        queue.submit([request("DEMO000001")], SETTINGS)
        self.assertTrue(self.started.wait(5))
        queue.pacing_changed()
        self.release.set()
        self.assertTrue(self.finished.wait(5))
        self.assertEqual(queue.snapshot()["current"]["jobs"][0]["status"], "Completed")

    def test_adding_a_title_preserves_account_options_and_deduplicates(self):
        def run(job, settings, cancelled, update):
            self.started.set()
            self.assertTrue(self.release.wait(5))
            return [], []

        queue = self.create(run)
        one = request("DEMO000001")
        one["options"] = {"destination": "Sample archive", "downloadAudio": False}
        queue.submit([one], SETTINGS)
        self.assertTrue(self.started.wait(5))
        with self.assertRaisesRegex(ValueError, "same account"):
            queue.submit([request("DEMO000002", "other")], SETTINGS, add=True)
        self.assertEqual(queue.submit([request("DEMO000001"), request("DEMO000003")], SETTINGS, add=True), 1)
        jobs = queue.snapshot()["current"]["jobs"]
        self.assertEqual(jobs[1]["options"], one["options"])
        self.release.set()
        self.assertTrue(self.finished.wait(5))

    def test_interrupted_jobs_restore_and_can_be_retried(self):
        job = dict(request("DEMO000001"), id="existing", status="Running", detail="Downloading", progress=0.5, files=[])
        write_json(self.path, {"current": {"id": "batch", "date": DATE,
                                           "jobs": [job], "settings": SETTINGS}, "history": []})
        queue = self.create(lambda *args: ([], []))
        self.assertEqual(queue.snapshot()["current"]["jobs"][0]["status"], "Interrupted")
        self.assertEqual(queue.retry("batch"), 1)
        self.assertTrue(self.finished.wait(5))
        self.assertEqual(queue.snapshot()["current"]["jobs"][0]["status"], "Completed")

    def test_stops_waiting_work_on_a_failure_when_configured(self):
        def fail(*args):
            raise RuntimeError("Synthetic failure")

        queue = self.create(fail)
        queue.submit([request("DEMO000001"), request("DEMO000002")], dict(SETTINGS, continue_after_error=False))
        self.assertTrue(self.finished.wait(5))
        self.assertEqual([job["status"] for job in queue.snapshot()["current"]["jobs"]], ["Failed", "Stopped"])


    def test_failed_initial_write_leaves_the_previous_queue_and_does_not_start_a_worker(self):
        queue = self.create(lambda *args: (self.started.set() or [], []))
        previous = queue.snapshot()
        with (patch("downaudible_windows.queue.write_json", side_effect=PermissionError("Read-only profile")),
              self.assertRaises(PermissionError)):
            queue.submit([request("DEMO000001")], SETTINGS)
        self.assertEqual(queue.snapshot(), previous)
        self.assertFalse(queue.active)
        self.assertFalse(self.started.is_set())

    def test_failed_retry_write_preserves_interrupted_job(self):
        job = dict(request("DEMO000001"), id="interrupted", status="Interrupted", detail="", progress=None, files=[])
        write_json(self.path, {"current": {"id": "batch", "date": DATE, "jobs": [job], "settings": SETTINGS}, "history": []})
        queue = self.create(lambda *args: (self.started.set() or [], []))
        with (patch("downaudible_windows.queue.write_json", side_effect=PermissionError("Read-only profile")),
              self.assertRaises(PermissionError)):
            queue.retry("batch", restart=True)
        self.assertEqual(queue.snapshot()["current"]["jobs"], [job])
        self.assertFalse(queue.active)
        self.assertFalse(self.started.is_set())

    def test_aax_retry_updates_only_selected_aax_work_and_can_return_to_account_credentials(self):
        old_reference, old_value = "activation-previous", "00001111"
        new_value = "1a2B3c4D"
        jobs = [
            failed_job("edit", "Edit", source="Part 1.m4b", sources=["Part 1.m4b", "Part 2.AAX"],
                       activation_reference=old_reference),
            failed_job("conversion", "Conversion", source="Other.aax", activation_reference=old_reference),
            failed_job("clear-audio", "Conversion", source="Unprotected.m4b"),
            failed_job("download", "Download", book={"asin": "DEMO000001"}, options={}),
        ]
        write_json(self.path, {"current": {"id": "batch", "date": DATE, "jobs": jobs, "settings": SETTINGS}, "history": []})
        client = AudibleClient(self.folder, self.folder)
        runner = JobRunner(self.folder, client, Mock())
        credentials = {}

        def run(job, *args):
            credentials[job["id"]] = runner._job_code(job)
            raise RuntimeError("Synthetic retry failure")

        with fixture_activation_vault():
            client.save_session(old_reference, old_value)
            queue = self.create(run)
            prepare_activation = partial(runner.retry_activation_reference, new_value)
            self.assertEqual(queue.retry("batch", {"edit", "clear-audio", "download"}, prepare_activation=prepare_activation), 3)
            self.assertTrue(self.finished.wait(5))
            edit, conversion, clear_audio, download = read_json(self.path)["current"]["jobs"]
            reference = edit["activation_reference"]
            self.assertEqual(client.session(reference), new_value)
            self.assertNotIn(new_value.encode(), (self.folder / "Accounts" / f"{reference}.dpapi").read_bytes())
            self.assertNotIn(new_value, self.path.read_text())
            self.assertEqual(conversion["activation_reference"], old_reference)
            self.assertEqual(client.session(old_reference), old_value)
            self.assertNotIn("activation_reference", clear_audio)
            self.assertNotIn("activation_reference", download)
            self.assertEqual(credentials, {"edit": new_value, "clear-audio": "", "download": ""})

            self.finished.clear()
            self.assertEqual(queue.retry("batch", {"edit"},
                                         prepare_activation=partial(runner.retry_activation_reference, "")), 1)
            self.assertTrue(self.finished.wait(5))
            self.assertNotIn("activation_reference", queue.snapshot()["current"]["jobs"][0])
            self.assertEqual(credentials["edit"], "")

    def test_aax_retry_write_failure_discards_new_vault_entry(self):
        old_reference = "activation-previous"
        original_job = failed_job("aax", "Conversion", source="Book.aax", activation_reference=old_reference)
        original_state = {"current": {"id": "batch", "date": DATE, "jobs": [original_job], "settings": SETTINGS},
                          "history": []}
        write_json(self.path, original_state)
        client = AudibleClient(self.folder, self.folder)
        runner = JobRunner(self.folder, client, Mock())
        executor = Mock(return_value=([], []))
        queue = self.create(executor)
        with fixture_activation_vault():
            client.save_session(old_reference, "00001111")
            entries = set((self.folder / "Accounts").iterdir())
            with (patch("downaudible_windows.queue.write_json", side_effect=PermissionError("Read-only profile")),
                  self.assertRaises(PermissionError)):
                queue.retry("batch", prepare_activation=partial(runner.retry_activation_reference, "1a2B3c4D"))
            self.assertEqual(queue.snapshot(), original_state)
            self.assertEqual(set((self.folder / "Accounts").iterdir()), entries)
            self.assertEqual(client.session(old_reference), "00001111")
            executor.assert_not_called()

    def test_restart_is_consumed_and_retry_keeps_the_new_receipt(self):
        def run(job, settings, cancelled, update):
            if job["restart"]:
                update("Restarted", milestone="downloadRestarted")
                raise OSError("Interrupted after restarting")
            self.second.set()
            return [], []

        queue = self.create(run)
        queue.submit([dict(request("DEMO000001"), restart=True)], SETTINGS)
        self.assertTrue(self.finished.wait(5))
        batch = queue.snapshot()["current"]
        job = batch["jobs"][0]
        self.assertFalse(job["restart"])
        self.assertTrue(job["replacement_id"])
        self.finished.clear()
        self.assertEqual(queue.retry(batch["id"]), 1)
        self.assertTrue(self.second.wait(5))
        self.assertTrue(self.finished.wait(5))
        self.assertEqual(queue.snapshot()["current"]["jobs"][0]["replacement_id"], job["replacement_id"])

    def test_download_cannot_be_added_to_conversion_or_cancelled_batch(self):
        def run(*args):
            self.started.set()
            self.assertTrue(self.release.wait(5))
            return [], []

        queue = self.create(run)
        queue.submit([{"kind": "Conversion", "title": "Local Audio"}], SETTINGS)
        self.assertTrue(self.started.wait(5))
        with self.assertRaisesRegex(ValueError, "same account"):
            queue.submit([request("DEMO000001")], SETTINGS, add=True)
        queue.cancel()
        with self.assertRaisesRegex(ValueError, "cancelled batch"):
            queue.submit([request("DEMO000001")], SETTINGS, add=True)

    def test_append_is_bound_to_the_confirmed_batch(self):
        def run(*args):
            self.started.set()
            self.assertTrue(self.release.wait(5))
            return [], []

        queue = self.create(run)
        queue.submit([request("DEMO000001")], SETTINGS)
        self.assertTrue(self.started.wait(5))
        batch, titles = queue.download_addition_state("example")
        self.assertEqual(titles, {"DEMO000001"})
        self.assertIsNone(queue.download_addition_state("other"))
        with self.assertRaisesRegex(ValueError, "running batch changed"):
            queue.submit([request("DEMO000002")], SETTINGS, add=True, expected_batch="previous")
        self.assertEqual(queue.submit([request("DEMO000002")], SETTINGS, add=True, expected_batch=batch), 1)
        self.release.set()
        self.assertTrue(self.finished.wait(5))
        with self.assertRaisesRegex(ValueError, "running batch changed"):
            queue.submit([request("DEMO000003")], SETTINGS, add=True, expected_batch=batch)

    def test_cancelled_only_run_does_not_announce_completion(self):
        def run(job, settings, stop, update):
            self.started.set()
            self.assertTrue(stop.wait(5))
            raise InterruptedError("Cancelled")

        queue = self.create(run)
        queue.submit([request("DEMO000001")], SETTINGS)
        self.assertTrue(self.started.wait(5))
        identifier = queue.snapshot()["current"]["jobs"][0]["id"]
        queue.cancel({identifier})
        queue.workers.shutdown(wait=True)
        self.assertEqual(queue.snapshot()["current"]["jobs"][0]["status"], "Cancelled")
        self.assertFalse(self.finished.is_set())

    def test_transfer_log_ignores_cancellation_and_keeps_original_failure_details(self):
        queue = self.create(lambda *args: ([], []))
        cancelled = {"title": "Cancelled book", "status": "Cancelled", "detail": "Cancelled by user"}
        default_log = self.folder / "Transfers.log"
        queue._write_log(cancelled, {"log_level": "results"})
        self.assertFalse(default_log.exists())
        failed = {"title": "Failed book", "status": "Failed", "detail": "Connection closed."}
        missing_log = self.folder / "Unavailable" / "Transfers.log"
        queue._write_log(failed, {"log_level": "errors", "log_file": str(missing_log)})
        self.assertFalse(missing_log.parent.exists())
        self.assertEqual(failed["status"], "Failed")
        self.assertEqual(failed["detail"], "Connection closed. The transfer log could not be written.")

    def test_failed_fallback_reports_download_failure_instead_of_completion(self):
        def run(job, settings, stop, update):
            update("Audio downloaded", milestone="downloadCompleted")
            update("Preparing conversion", milestone="preparingConversion")
            update("Downloading AAXC fallback", milestone="downloading")
            raise ValueError("Fallback unavailable")

        reports = []
        queue = self.create(run)

        def finished(batch, events, settings):
            reports.append(events)
            self.finished.set()

        queue.finished = finished
        queue.submit([request("DEMO000001")], SETTINGS)
        self.assertTrue(self.finished.wait(5))
        job = queue.snapshot()["current"]["jobs"][0]
        self.assertEqual(job["status"], "Failed")
        self.assertEqual(reports, [{"downloadFailed": {job["id"]}}])

    def test_preserves_malformed_or_invalid_queue_and_saves_new_transfers(self):
        for original in (b'{"current":', b'\xff\xff', b'null', b'{"current":null,"history":[{"jobs":[]}]}'):
            with self.subTest(original=original):
                self.path.write_bytes(original)
                queue = self.create(lambda *args: ([], []))
                self.assertEqual(queue.snapshot(), {"current": None, "history": []})
                before = set(self.folder.glob("Queue.unreadable-*.json"))
                backup = next(path for path in before if path.read_bytes() == original)
                self.assertIn(str(backup), queue.recovery_warning)
                self.assertFalse(self.path.exists())
                self.finished.clear()
                queue.submit([request("DEMO000001")], SETTINGS)
                self.assertTrue(self.finished.wait(5))
                self.assertEqual(read_json(self.path)["current"]["jobs"][0]["status"], "Completed")
                self.assertEqual(backup.read_bytes(), original)

    def test_queue_with_locked_original_refuses_to_overwrite_until_it_can_be_preserved(self):
        original = b"damaged queue"
        self.path.write_bytes(original)
        with patch.object(Path, "rename", side_effect=PermissionError("Queue locked")):
            queue = self.create(lambda *args: ([], []))
            self.assertIn("original queue is still at", queue.recovery_warning)
            with self.assertRaises(PermissionError):
                queue.submit([request("DEMO000001")], SETTINGS)
            self.assertEqual(self.path.read_bytes(), original)
            self.assertIsNone(queue.snapshot()["current"])
        queue.submit([request("DEMO000001")], SETTINGS)
        self.assertTrue(self.finished.wait(5))
        (backup,) = self.folder.glob("Queue.unreadable-*.json")
        self.assertEqual(backup.read_bytes(), original)

    def test_history_removal_preserves_the_current_batch_and_other_historical_jobs(self):
        complete = dict(request("DEMO000001"), id="first", status="Completed", detail="Saved", files=[])
        failed = dict(request("DEMO000002"), id="second", status="Failed", detail="Error", files=[])
        previous = {"id": "older", "date": DATE, "jobs": [complete, failed], "settings": SETTINGS}
        write_json(self.path, {"current": None, "history": [previous]})

        def run(*args):
            self.started.set()
            self.release.wait(5)
            return [], []

        queue = self.create(run)
        queue.submit([request("DEMO000003")], SETTINGS)
        self.assertTrue(self.started.wait(5))
        queue.remove(completed_only=True, batch_id="older")
        self.assertEqual(queue.snapshot()["history"][0]["jobs"], [failed])
        queue.remove({"second"}, batch_id="older")
        self.assertEqual(queue.snapshot()["history"], [])
        self.assertEqual(queue.snapshot()["current"]["jobs"][0]["title"], "DEMO000003")
        self.release.set()

    def test_restart_of_historical_job_uses_its_saved_batch_settings(self):
        first = dict(request("DEMO000001"), id="first", status="Failed", detail="Error", files=[])
        second = dict(request("DEMO000002"), id="second", status="Failed", detail="Error", files=[])
        previous = {"id": "older", "date": DATE, "jobs": [first, second], "settings": SETTINGS}
        write_json(self.path, {"current": None, "history": [previous]})
        started = []

        def has_partial(job, settings):
            self.assertEqual(settings, SETTINGS)
            return job["id"] == "second"

        def run(job, *args):
            started.append((job["id"], job["restart"]))
            return [], []

        queue = self.create(run, has_partial=has_partial)
        self.assertEqual(queue.retry("older", {"first"}, restart=True), 0)
        self.assertEqual(queue.retry("older", restart=True), 1)
        self.assertTrue(self.finished.wait(5))
        self.assertEqual(started, [("second", True)])

    def test_close_saves_an_interrupted_snapshot_before_stopping_workers(self):
        worker_cancelled = Event()
        saved_output = self.folder / "Example.m4b"

        def run(job, settings, stop, update):
            self.started.set()
            self.assertTrue(stop.wait(5))
            worker_cancelled.set()
            self.assertTrue(self.release.wait(5))
            update("Partial output", files=[saved_output])
            raise InterruptedError("Stopped")

        queue = self.create(run)
        queue.submit([request("DEMO000001"), request("DEMO000002")], SETTINGS)
        self.assertTrue(self.started.wait(5))
        with (patch("downaudible_windows.queue.write_json", side_effect=PermissionError("Read-only profile")),
              self.assertRaises(PermissionError)):
            queue.prepare_close()
        self.assertFalse(queue.closing)
        self.assertFalse(worker_cancelled.is_set())
        self.assertEqual([job["status"] for job in queue.snapshot()["current"]["jobs"]], ["Running", "Waiting"])

        queue.prepare_close()
        self.assertTrue(worker_cancelled.wait(5))
        before = read_json(self.path)["current"]["jobs"]
        self.assertEqual([job["status"] for job in before], ["Interrupted", "Interrupted"])
        self.release.set()
        queue.workers.shutdown()
        queue.save()
        self.assertEqual(read_json(self.path)["current"]["jobs"][0]["files"], [str(saved_output)])
        queue.reopen()
        self.assertFalse(queue.closing)

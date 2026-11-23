import tempfile
import unittest
from pathlib import Path
from threading import Event
from time import monotonic, sleep

from downaudible_windows.queue import BatchQueue
from downaudible_windows.refusal import Refusals, RetryAfter


class ManualTimer:
    def __init__(self, delay, callback):
        self.callback = callback

    def start(self):
        pass

    def cancel(self):
        pass


class RefusalTests(unittest.TestCase):
    START = 1_750_000_000.0

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.now = self.START

    def clock(self):
        return self.now

    def test_refusals_persist_per_account_and_only_for_specific_errors(self):
        path = self.path / "refusals.json"
        gates = Refusals(path, clock=self.clock)
        gates.record("a", "licenseEntitlement", "Not entitled")
        with self.assertRaises(RetryAfter) as error:
            gates.record("a", "rateLimited", "Refused")
        self.assertEqual(error.exception.until, self.START + 900)
        self.assertTrue(error.exception.new)
        reopened = Refusals(path, clock=self.clock)
        reopened.check("b", str)
        with self.assertRaises(RetryAfter) as waiting:
            reopened.check("a", str)
        self.assertFalse(waiting.exception.new)
        self.now = self.START + 900
        reopened.check("a", str)

    def test_queue_displays_refusal_time_and_retries_a_job_once(self):
        asked = Event()
        attempts = []

        def execute(job, settings, stop, update):
            attempts.append(job["id"])
            asked.set()
            raise RetryAfter(self.now + 10, "Audible refused.", new=True)

        queue = BatchQueue(self.path / "queue.json", execute, lambda: None, lambda *_args: None,
                           clock=self.clock, timer=ManualTimer)
        self.addCleanup(queue.close)
        queue.submit([{"kind": "Download", "title": "Fixture", "book": {"asin": "DEMO000001"}, "options": {}}], {})

        def wait_status(status):
            deadline = monotonic() + 2
            while monotonic() < deadline:
                row = queue.snapshot()["current"]["jobs"][0]
                if row["status"] == status:
                    return row
                sleep(0.01)
            self.fail(f"Queue did not reach {status!r}")

        self.assertTrue(asked.wait(2))
        waiting = wait_status("Waiting")
        self.assertEqual(waiting["refusal_until"], self.START + 10)
        self.assertIn("Next retry", waiting["detail"])
        self.now = self.START + 10
        queue._pacing_timer.callback()
        failed = wait_status("Failed")
        self.assertEqual(failed["refusal_attempts"], 2)
        self.assertIn("Try again after", failed["detail"])
        self.assertEqual(len(attempts), 2)

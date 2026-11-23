"""Exercise the rolling audio limit without waiting or contacting Audible."""

from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase

from downaudible_windows.pacing import WINDOW_SECONDS, DownloadDeferred, DownloadPacer


class PacingTests(TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "Download Usage.json"
        self.now = 100_000
        self.pacer = self.open_pacer()

    def open_pacer(self):
        return DownloadPacer(self.path, clock=lambda: self.now)

    def count(self, job, received, *, plus=False):
        with self.pacer.reserve(job, plus=plus) as record:
            record(received)

    def test_book_limit_persists_across_restarts_and_expires_per_download(self):
        self.count("First", 10)
        self.now += 200
        self.count("Second", 10)
        self.pacer = self.open_pacer()
        self.pacer.configure({"scope": "all", "quantity": 2})
        with self.assertRaises(DownloadDeferred) as limit:
            self.count("Third", 10)
        self.assertEqual(limit.exception.until, 100_000 + WINDOW_SECONDS)
        self.now = limit.exception.until
        self.count("Third", 10)
        with self.assertRaises(DownloadDeferred) as next_limit:
            self.count("Fourth", 10)
        self.assertEqual(next_limit.exception.until, 100_200 + WINDOW_SECONDS)

    def test_live_book_reservations_prevent_overcommit_and_release_on_failure(self):
        self.pacer.configure({"scope": "all", "quantity": 1})
        with self.assertRaises(OSError), self.pacer.reserve("Failed"):
            with self.assertRaises(DownloadDeferred) as wait:
                self.count("Second", 10)
            self.assertIsNone(wait.exception.until)
            raise OSError("Synthetic failure")
        self.count("Second", 10)
        self.count("Second", 2)
        self.assertEqual(sum(entry.books for entry in self.pacer.usage), 1)
        self.assertEqual(sum(entry.bytes for entry in self.pacer.usage), 12)

    def test_plus_limit_leaves_owned_and_unknown_titles_unrestricted(self):
        self.pacer.configure({"scope": "plus", "quantity": 1})
        self.count("Plus", 10, plus=True)
        self.count("Purchased", 10, plus=False)
        self.count("Unknown", 10, plus=None)
        with self.assertRaises(DownloadDeferred):
            self.count("Another Plus", 10, plus=True)

    def test_byte_limit_serializes_unknown_downloads_and_allows_an_oversize_first_title(self):
        self.pacer.configure({"scope": "all", "quantity": 1, "unit": "mb"})
        with self.pacer.reserve("Large") as record:
            with self.assertRaises(DownloadDeferred) as wait:
                self.count("Second", 10)
            self.assertIsNone(wait.exception.until)
            record(1_200_000)
        with self.assertRaises(DownloadDeferred) as limit:
            self.count("Second", 10)
        self.assertEqual(limit.exception.until, self.now + WINDOW_SECONDS)
        self.now += WINDOW_SECONDS
        self.count("Second", 0)
        self.assertEqual(self.pacer.usage, [])

    def test_invalid_saved_deadline_is_preserved_and_reports_a_usage_error(self):
        original = '[{"time":1e100,"job":"Old","plus":false,"books":1,"bytes":10}]'
        self.path.write_text(original, encoding="utf-8")
        self.pacer = self.open_pacer()
        self.pacer.configure({"scope": "all", "quantity": 1})
        with self.assertRaisesRegex(OSError, "couldn’t read its daily download usage"):
            self.count("New", 10)
        self.assertEqual(self.path.read_text(encoding="utf-8"), original)

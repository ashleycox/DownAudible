"""Tests for source reuse and fallback without service accounts."""

from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event, Thread
from unittest import TestCase
from unittest.mock import Mock

from downaudible_windows.audible import AudibleError
from downaudible_windows.jobs import JobRunner
from downaudible_windows.media import OutputSpec
from downaudible_windows.pacing import DownloadDeferred
from downaudible_windows.queue import BatchQueue
from downaudible_windows.state import DEFAULTS


class LibraryJobTests(TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.settings = deepcopy(DEFAULTS)
        self.settings["archive_root"] = str(self.root / "Audiobooks")
        self.settings["conversion"].update(embed_chapters=False, embed_artwork=False)
        self.client = Mock()
        self.tools = Mock()
        self.tools.convert.side_effect = self.convert
        self.runner = JobRunner(self.root / "App", self.client, self.tools)
        self.sources = []
        self.book = {"asin": "DEMO000001", "title": "Sample Book", "authors": ["Example Author"], "isDownloadable": True}
        self.job = {"id": "sample-job", "kind": "Download", "title": "Sample Book", "book": self.book,
                    "options": {"downloadAudio": True, "convert": True, "keepOriginal": True},
                    "account_id": "example"}

    def convert(self, inputs, directory, options, *, destinations, **fields):
        self.sources = [item.path for item in inputs]
        output, = destinations([OutputSpec("m4b")])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"synthetic output")
        return [output]

    def run_job(self):
        return self.runner.run(self.job, self.settings, Event(), Mock())

    def test_existing_matched_audio_converts_without_downloading_again(self):
        audio = self.root / "Matched Audio.m4a"
        audio.write_bytes(b"synthetic original")
        self.job["matched_sources"] = [str(audio)]
        result, warnings = self.run_job()
        self.assertEqual(self.sources, [audio])
        self.assertEqual(warnings, [])
        self.assertEqual(set(path.suffix for path in result), {".m4a", ".m4b"})
        self.assertEqual(audio.read_bytes(), b"synthetic original")
        self.client.run.assert_not_called()

    def test_widevine_uses_only_the_opted_in_accounts_automatic_format(self):
        self.runner.widevine_enabled = lambda account: account == "example"
        self.client.widevine_cdm.return_value = "Zml4dHVyZQ=="
        self.tools.ffmpeg = self.root / "ffmpeg.exe"
        for account, mode in (("another-account", "preferAAX"), ("example", "aaxOnly"), ("example", "aaxcOnly")):
            self.assertEqual(self.runner.widevine_download_fields(account, {"format": mode}), {})
        self.client.widevine_cdm.assert_not_called()

        def download(command, **fields):
            self.assertEqual(command, "download")
            self.assertEqual(fields["account_id"], "example")
            self.assertEqual(fields["widevineCDM"], "Zml4dHVyZQ==")
            self.assertEqual(fields["ffmpeg"], str(self.tools.ffmpeg))
            self.assertNotIn("widevineCDM", fields["options"])
            source = Path(fields["directory"]) / "Source.m4a"
            source.write_bytes(b"synthetic source")
            return {"parts": [{"file": source.name}]}

        self.client.run.side_effect = download
        outputs, warnings = self.run_job()
        self.client.widevine_cdm.assert_called_once_with("example")
        self.assertEqual(warnings, [])
        self.assertEqual({path.suffix for path in outputs}, {".m4a", ".m4b"})

    def test_pacing_counts_transferred_audio_bytes_and_leaves_local_conversion_available(self):
        def audible(command, **fields):
            self.assertEqual(command, "download")
            path = Path(fields["directory"]) / "Source.m4a"
            path.write_bytes(b"bigger than the transferred portion")
            return {"parts": [{"file": path.name, "downloadedBytes": 5}]}

        self.runner.pacer.configure({"scope": "all", "unit": "books", "quantity": 1})
        self.client.run.side_effect = audible
        self.run_job()
        self.assertEqual([entry.bytes for entry in self.runner.pacer.usage], [5])
        self.job["id"] = "second-job"
        self.book.update(asin="DEMO000002", title="Second Book")
        with self.assertRaises(DownloadDeferred):
            self.run_job()
        self.client.run.assert_called_once()
        matched = self.root / "Matched.m4a"
        matched.write_bytes(b"synthetic local audio")
        self.job["matched_sources"] = [str(matched)]
        _, warnings = self.run_job()
        self.assertEqual(warnings, [])
        self.assertEqual(self.sources, [matched])
        self.client.run.assert_called_once()
        self.assertEqual(len(self.runner.pacer.usage), 1)

    def test_audible_activation_error_uses_fallback_and_keeps_saved_aax(self):
        def audible(command, *, options, **fields):
            if command == "activation":
                raise AudibleError("activation")
            self.assertEqual(command, "download")
            suffix = ".aaxc" if options["format"] == "aaxcOnly" else ".aax"
            file = Path(fields["directory"]) / ("Sample" + suffix)
            file.write_bytes(b"synthetic source")
            credentials = {"contentKey": "0" * 32, "contentIV": "1" * 32} if suffix == ".aaxc" else {}
            return {"parts": [{"file": file.name, "credentials": credentials}]}

        self.client.run.side_effect = audible
        result, warnings = self.run_job()
        self.assertEqual(warnings, [])
        self.assertEqual(self.sources[0].suffix, ".aaxc")
        self.assertEqual(set(path.suffix for path in result), {".aax", ".m4b"})
        self.assertTrue(all(path.exists() for path in result))

    def test_aaxc_fallback_waits_for_the_same_batch_download_slot(self):
        self.settings.update(download_limit=1, conversion_limit=1)
        other = deepcopy(self.job)
        other["title"] = other["book"]["title"] = "Other Book"
        other["book"]["asin"] = "DEMO000002"
        second_downloading, release_second = Event(), Event()
        waiting, fallback_downloading, release_fallback = Event(), Event(), Event()
        second_converting, finished = Event(), Event()

        def audible(command, *, options, **fields):
            if command == "activation":
                self.assertTrue(second_downloading.wait(5))
                raise AudibleError("activation")
            self.assertEqual(command, "download")
            credentials = {}
            if fields["asin"] == other["book"]["asin"]:
                suffix = ".m4a"
                second_downloading.set()
                self.assertTrue(release_second.wait(5))
            elif options["format"] == "aaxcOnly":
                suffix = ".aaxc"
                credentials = {"contentKey": "0" * 32, "contentIV": "1" * 32}
                fallback_downloading.set()
                self.assertTrue(release_fallback.wait(5))
            else:
                suffix = ".aax"
            path = Path(fields["directory"]) / ("Sample" + suffix)
            path.write_bytes(b"synthetic source")
            return {"parts": [{"file": path.name, "credentials": credentials}]}

        def convert(inputs, *args, **fields):
            if fields["metadata"]["asin"] == other["book"]["asin"]:
                second_converting.set()
            return self.convert(inputs, *args, **fields)

        def changed():
            jobs = queue.snapshot()["current"]["jobs"]
            if jobs[0]["detail"] == "Waiting for an available download slot":
                waiting.set()

        self.client.run.side_effect = audible
        self.tools.convert.side_effect = convert
        queue = BatchQueue(self.root / "Queue.json", self.runner.run, changed, lambda *args: finished.set())
        self.addCleanup(queue.workers.shutdown)
        self.addCleanup(release_second.set)
        self.addCleanup(release_fallback.set)
        queue.submit([self.job, other], self.settings)
        self.assertTrue(second_downloading.wait(5))
        self.assertTrue(waiting.wait(5))
        self.assertFalse(fallback_downloading.is_set())
        release_second.set()
        self.assertTrue(fallback_downloading.wait(5))
        self.assertTrue(second_converting.wait(5))
        release_fallback.set()
        self.assertTrue(finished.wait(5))
        self.assertEqual([job["status"] for job in queue.snapshot()["current"]["jobs"]], ["Completed", "Completed"])

    def test_waiting_for_a_download_slot_is_cancellable(self):
        self.settings["download_limit"] = 1
        stop, waiting, interrupted = Event(), Event(), Event()

        def run():
            try:
                with self.runner.transfer_slot("download", self.settings, stop, lambda detail: waiting.set()):
                    pass
            except InterruptedError:
                interrupted.set()

        with self.runner.transfer_slot("download", self.settings, Event(), Mock()):
            waiter = Thread(target=run)
            waiter.start()
            self.addCleanup(waiter.join, 5)
            self.assertTrue(waiting.wait(5))
            stop.set()
            self.assertTrue(interrupted.wait(5))


    def test_missing_companion_retries_only_its_group_and_keeps_the_archive_layout(self):
        self.book["hasPDF"] = False

        def audible(command, **fields):
            folder = Path(fields["directory"])
            if command == "download":
                path = folder / "Source.m4a"
                path.write_bytes(b"synthetic original")
                return {"parts": [{"file": path.name}]}
            self.assertEqual(command, "jsonExtras")
            path = folder / "chapters.json"
            path.write_text("{}", encoding="utf-8")
            return {"chapters": path.name}

        self.client.run.side_effect = audible
        audio_only, warnings = self.run_job()
        self.assertFalse(warnings)
        self.client.run.reset_mock()
        self.job["options"].update(downloadChapters=True, downloadPDF=True)
        first, warnings = self.run_job()
        self.assertFalse(warnings)
        self.client.run.assert_called_once()
        self.assertEqual(first[:2], audio_only)
        original, converted, chapters = first
        self.assertEqual(original.parent, chapters.parent)
        self.assertEqual(chapters.name, "Sample Book - Chapters.json")
        self.assertEqual(converted.suffix, ".m4b")
        chapters.unlink()
        self.client.run.reset_mock()
        self.tools.convert.reset_mock()
        second, warnings = self.run_job()
        self.assertFalse(warnings)
        self.assertEqual(first, second)
        self.client.run.assert_called_once()
        self.assertEqual(self.client.run.call_args.args, ("jsonExtras",))
        self.tools.convert.assert_not_called()

    def test_restart_download_ignores_matches_and_existing_receipts(self):
        local = self.root / "Matched.m4a"
        local.write_bytes(b"synthetic local source")
        self.job["matched_sources"] = [str(local)]
        old, _ = self.run_job()

        def audible(command, **fields):
            self.assertEqual(command, "download")
            path = Path(fields["directory"]) / "New.m4a"
            path.write_bytes(b"new source")
            return {"parts": [{"file": path.name}]}

        self.client.run.side_effect = audible
        self.job.update(restart=True, replacement_id="replacement")
        new, _ = self.run_job()
        self.assertEqual(len(new), 2)
        self.assertTrue(set(old).isdisjoint(new))
        self.assertEqual(new[0].read_bytes(), b"new source")
        self.job["restart"] = False
        self.client.run.reset_mock()
        retried, _ = self.run_job()
        self.assertEqual(new, retried)
        self.client.run.assert_not_called()

    def test_partial_download_paths_are_scoped_to_destination(self):
        standard = self.runner.stage_for(self.job, self.settings)
        self.job["options"]["destination"] = str(self.root / "Another archive")
        different = self.runner.stage_for(self.job, self.settings)
        self.assertNotEqual(standard.path, different.path)
        standard.path.mkdir(parents=True)
        self.assertFalse(self.runner.has_partial(self.job, self.settings))

    def test_player_retries_are_independent_of_companion_warnings_and_audio_mode(self):
        def audible(command, **fields):
            if command == "extras":
                return {}
            self.assertEqual(command, "download")
            path = Path(fields["directory"]) / "Source.m4a"
            path.write_bytes(b"synthetic source")
            return {"parts": [{"file": path.name}]}

        self.client.run.side_effect = audible
        player = self.runner._open_in_player = Mock()
        self.job["options"].update(open_after_saving="original", downloadPDF=True)
        files, warnings = self.run_job()
        original, converted = files
        player.assert_called_once_with(original)
        self.assertIn("Companion PDF unavailable.", warnings)

        self.run_job()
        player.assert_called_once_with(original)
        player.reset_mock()
        self.job["options"]["open_after_saving"] = "converted"
        player.side_effect = OSError("No default player")
        retried, warnings = self.run_job()
        self.assertEqual(retried, files)
        player.assert_called_once_with(converted)
        self.assertTrue(any("could not open" in warning for warning in warnings))

        player.side_effect = None
        player.reset_mock()
        self.run_job()
        player.assert_called_once_with(converted)
        self.run_job()
        player.assert_called_once_with(converted)

    def test_failed_pdf_save_preserves_audio_and_still_saves_chapters(self):
        def audible(command, **fields):
            folder = Path(fields["directory"])
            key, name = {"download": ("audio", "Source.m4a"), "extras": ("pdf", "book.pdf"),
                         "jsonExtras": ("chapters", "chapters.json")}[command]
            (folder / name).write_bytes(b"synthetic fixture")
            return {"parts": [{"file": name}]} if key == "audio" else {key: name}

        self.client.run.side_effect = audible
        save_file = self.runner._save_download_file

        def save(layout, book, files, stop, source, **naming):
            if source.suffix == ".pdf":
                raise OSError("Archive file unavailable")
            return save_file(layout, book, files, stop, source, **naming)

        self.runner._save_download_file = save
        self.job["options"].update(downloadPDF=True, downloadChapters=True)

        files, warnings = self.run_job()
        self.assertEqual({path.suffix for path in files}, {".m4a", ".m4b", ".json"})
        self.assertTrue(any("Could not save companion pdf" in warning for warning in warnings))

    def test_cleanup_preference_does_not_duplicate_identical_output(self):
        def audible(command, **fields):
            self.assertEqual(command, "download")
            path = Path(fields["directory"]) / "Source.m4a"
            path.write_bytes(b"synthetic source")
            return {"parts": [{"file": path.name}]}

        self.client.run.side_effect = audible
        files, _ = self.run_job()
        self.client.run.reset_mock()
        self.tools.convert.reset_mock()
        self.settings["conversion"].update(move_aax_to_trash=True, mp3_bitrate_mode="variable", mp3_quality=8)

        reused, warnings = self.run_job()

        self.assertEqual(reused, files)
        self.assertFalse(warnings)
        self.client.run.assert_not_called()
        self.tools.convert.assert_not_called()

    def test_partial_detection_requires_nonempty_audio_and_includes_fallback(self):
        stage = self.runner.stage_for(self.job, self.settings)
        folder = stage.prepare()
        (folder / "Companion.pdf.partial").write_bytes(b"some bytes")
        (folder / "Empty.aax.partial").touch()
        self.assertFalse(self.runner.has_partial(self.job, self.settings))
        fallback = folder / "Conversion Source"
        fallback.mkdir()
        (fallback / "Sample.aaxc.partial").write_bytes(b"some audio")
        self.assertTrue(self.runner.has_partial(self.job, self.settings))
        self.job["options"]["downloadAudio"] = False
        self.assertFalse(self.runner.has_partial(self.job, self.settings))


    def test_retry_requests_only_missing_cover_sizes_and_keeps_completed_artwork(self):
        self.settings["api"]["coverSizes"] = [500, 252]
        self.job["options"].update(downloadAudio=False, downloadCover=True)

        def audible(command, **fields):
            self.assertEqual(command, "extras")
            sizes = fields["options"]["coverSizes"]
            size = 500 if len(sizes) == 2 else sizes[0]
            cover = Path(fields["directory"]) / f"cover-{size}.jpg"
            cover.write_bytes(b"synthetic cover")
            return {"covers": [cover.name]}

        self.client.run.side_effect = audible
        files, warnings = self.run_job()
        self.assertEqual(len(files), 1)
        self.assertTrue(warnings)
        self.client.run.reset_mock()
        files, warnings = self.run_job()
        self.assertEqual([path.name for path in files], ["Sample Book - Cover 500.jpg", "Sample Book - Cover 252.jpg"])
        self.assertFalse(warnings)
        self.assertEqual(self.client.run.call_args.kwargs["options"]["coverSizes"], [252])

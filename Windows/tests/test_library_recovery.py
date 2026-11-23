import tempfile
import unittest
from pathlib import Path
from types import MethodType, SimpleNamespace
from unittest.mock import Mock

from downaudible_windows.archive import verify_archive
from downaudible_windows.state import write_json

try:
    from downaudible_windows.app import MainFrame
    from downaudible_windows.audible import AudibleError
    from downaudible_windows.library import LibraryPanel
    from downaudible_windows.media_views import BookEditor
except ModuleNotFoundError as error:
    if error.name not in {"wx", "markdown"}:
        raise
    MainFrame = None


class ArchiveVerificationTests(unittest.TestCase):
    def test_checks_staged_audio_and_ignores_unavailable_titles_without_files(self):
        books = [
            {"asin": "P", "isDownloadable": False},
            {"asin": "U", "isDownloadable": False},
            {"asin": "A", "isDownloadable": True},
        ]
        issues = verify_archive(books, {}, Mock(), has_partial=lambda book: book["asin"] == "P")
        self.assertEqual([(issue.book["asin"], issue.kind) for issue in issues], [
            ("P", "incomplete"), ("A", "missing"),
        ])


@unittest.skipIf(MainFrame is None, "Requires the Windows application runtime or wxPython")
class LibraryRecoveryTests(unittest.TestCase):
    def test_verification_scopes_receipts_and_includes_explicit_matches(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp).resolve()
            local, elsewhere = data / "Local", data / "Elsewhere"
            book = {"asin": "FIXTURE"}
            frame = SimpleNamespace(data_dir=data, settings={"audible_account": "acct"}, match_paths=lambda _: [data / "matched.m4b"])
            frame.archived_audio_copies = MethodType(MainFrame.archived_audio_copies, frame)
            for root in (local, elsewhere):
                write_json(data / "Receipts" / f"{root.name}.json", {
                    "asin": book["asin"], "account_id": "acct", "root": str(root),
                    "groups": {"audio": [str(root / "book.m4b")]},
                })
            MainFrame._load_receipts(frame)
            groups, _ = MainFrame.archive_verification_matches(frame, [book], root=local.resolve())
            self.assertEqual(groups[book["asin"]], [[data / "matched.m4b"], [local / "book.m4b"]])

    def test_inventory_uses_selected_archive_and_checks_whole_copies(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp).resolve()
            local, elsewhere = data / "Local", data / "Elsewhere"
            for folder in (local, elsewhere):
                folder.mkdir()
            first, truncated = local / "Part 1.m4b", local / "Part 2.m4b"
            first.write_bytes(b"test")
            truncated.write_bytes(b"x")
            other = elsewhere / "Book.m4b"
            other.write_bytes(b"test")
            for folder, files in ((local, (first, truncated)), (elsewhere, (other,))):
                write_json(data / "Receipts" / f"{folder.name}.json", {
                    "asin": "FIXTURE", "account_id": "acct", "root": str(folder),
                    "groups": {"audio": [str(file) for file in files]},
                    "sizes": {str(file): 4 for file in files},
                })
            frame = SimpleNamespace(data_dir=data, settings={"audible_account": "acct", "archive_root": str(local)},
                                    match_paths=Mock(return_value=[]), has_incomplete_download=lambda _: False, demo=False)
            for name in ("selected_archive_root", "archived_audio_copies", "matched_files"):
                setattr(frame, name, MethodType(getattr(MainFrame, name), frame))
            MainFrame._load_receipts(frame)
            book = {"asin": "FIXTURE", "isDownloadable": True}
            self.assertEqual(MainFrame.status_for(frame, book), "Files missing")
            self.assertEqual(MainFrame.receipt_audio_paths(frame, book), [])
            self.assertEqual(MainFrame.missing_output_files(frame, book), [truncated])

            frame.settings["archive_root"] = str(elsewhere)
            self.assertEqual(MainFrame.status_for(frame, book), "Downloaded")
            self.assertEqual(MainFrame.receipt_audio_paths(frame, book), [other])
            frame.settings["archive_root"] = str(data / "New Archive")
            self.assertEqual(MainFrame.status_for(frame, book), "Not downloaded")
            frame.match_paths.return_value = [first, local / "Absent Part.m4b"]
            self.assertEqual(MainFrame.status_for(frame, book), "Files missing")
            self.assertEqual(frame.matched_files(book), [])
            frame.match_paths.return_value = [first]
            self.assertEqual(MainFrame.status_for(frame, book), "Matched")

    def test_failed_account_removal_save_keeps_match_metadata(self):
        account = {"id": "acct"}
        matches = {"acct": {"FIXTURE": ["audio.m4b"]}, "other": {"OTHER": ["other.m4b"]}}
        frame = SimpleNamespace(
            settings={"audible_accounts": [account], "audible_account": "acct", "matches": matches},
            save_settings=Mock(side_effect=OSError("write failed")),
        )
        library = SimpleNamespace(frame=frame)
        with self.assertRaises(AudibleError):
            LibraryPanel._persist_accounts(library, [], None, removed_account="acct")
        self.assertIs(frame.settings["matches"], matches)
        self.assertEqual(frame.settings["audible_accounts"], [account])
        frame.save_settings.side_effect = None
        LibraryPanel._persist_accounts(library, [], None, removed_account="acct")
        self.assertEqual(frame.settings["matches"], {"other": matches["other"]})

    def test_completed_download_loads_the_audio_in_the_same_editor(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = Path(tmp) / "z-first.aax"
            second = Path(tmp) / "a-second.aax"
            first.touch()
            second.touch()
            job = {"id": "queued", "status": "Completed", "files": [str(first), str(second), str(first.with_suffix(".json"))]}
            editor = SimpleNamespace(
                frame=SimpleNamespace(queue=Mock(**{"snapshot.return_value": {"current": {"jobs": [job]}}})),
                download_job="queued", download_timer=Mock(), download_progress=Mock(),
                download_controls=object(), editor_controls=object(), GetSizer=Mock(),
                Layout=Mock(), _read_sources=Mock(),
            )
            BookEditor._download_update(editor)
            self.assertEqual(editor.paths, [first, second])
            editor.download_timer.Stop.assert_called_once()
            editor.GetSizer.return_value.Show.assert_any_call(editor.editor_controls, True)
            editor._read_sources.assert_called_once_with()

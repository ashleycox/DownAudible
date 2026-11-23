"""Check conversion preference persistence and editor submissions."""

from importlib.util import find_spec
from pathlib import Path
from threading import Event
from types import SimpleNamespace
from unittest import TestCase, skipUnless
from unittest.mock import Mock, patch

from downaudible_windows.media import BookSection, LocalAudio


@skipUnless(find_spec("wx"), "Convert Files requires wxPython")
class ConverterWorkflowTests(TestCase):
    def test_changes_are_saved_with_archive_settings_and_restore_on_failure(self):
        from downaudible_windows.media_views import ConverterPanel

        profile = {"format": "m4b"}
        frame = SimpleNamespace(settings={"conversion": profile}, save_settings=Mock())
        panel = SimpleNamespace(frame=frame, sync_settings=Mock())
        self.assertTrue(ConverterPanel._save_preference(panel, profile, "format", "mp3"))
        self.assertEqual(profile["format"], "mp3")
        frame.save_settings.side_effect = OSError("Read-only profile")
        with patch("downaudible_windows.media_views._tell") as error:
            self.assertFalse(ConverterPanel._save_preference(panel, profile, "format", "m4a"))
            error.assert_called_once()
        self.assertEqual(profile["format"], "mp3")
        self.assertIs(frame.settings["conversion"], profile)
        self.assertEqual(panel.sync_settings.call_count, 2)

    def test_local_parts_are_naturally_sorted_before_selecting_book_metadata(self):
        from downaudible_windows.media_views import _local_book_inputs

        part10 = LocalAudio(Path("Part 10.m4b"), "m4b", None, "Part 10", None, 10)
        part2 = LocalAudio(Path("Part 2.m4b"), "m4b", None, "Part 2", "Narrator", 10,
                           collection="Book Title", collection_author="Book Author")
        paths, metadata = _local_book_inputs([part10, part2, part2])
        self.assertEqual(paths, [part2.path, part10.path])
        self.assertEqual(metadata["title"], "Book Title")
        self.assertEqual(metadata["authors"], "Book Author")

    def test_failed_editor_submission_preserves_edits_for_a_retry(self):
        import wx
        from downaudible_windows.media_views import BookEditor

        source = Path("Book.m4b")
        frame = SimpleNamespace(guard=Mock(side_effect=[False, True]), enqueue_edit=Mock())
        dialog = SimpleNamespace(
            frame=frame,
            metadata={"title": "Original"},
            fields={"title": Mock(**{"GetValue.return_value": "Edited"})},
            layout=[BookSection(0, 0, "Part 1", 0, 1000, None), BookSection(1, 0, "Part 2", 1000, 2000, None)],
            sections=Mock(**{"IsItemChecked.side_effect": [False, True, False, True]}),
            paths=[source],
            revisions={str(source): (1, 1, 100, 10)},
            activation="",
            destination=None,
            book=None,
            chapters=None,
            chapter_repair=None,
            stop_preview=Mock(),
            EndModal=Mock(),
        )
        BookEditor.on_convert(dialog)
        dialog.EndModal.assert_not_called()
        dialog.stop_preview.assert_not_called()
        BookEditor.on_convert(dialog)
        dialog.EndModal.assert_called_once_with(wx.ID_OK)
        dialog.stop_preview.assert_called_once()
        _, enqueued_source, edit = frame.guard.call_args.args
        self.assertEqual(enqueued_source, source)
        self.assertEqual(edit["metadata"]["title"], "Edited")
        self.assertEqual(edit["excluded_sections"], [0])
        self.assertNotIn("chapter_repair", edit)

    def test_editor_requests_audible_chapters_only_for_an_identified_single_original(self):
        from downaudible_windows.media_views import BookEditor

        path = Path("Book.aax")
        cancel = Event()
        scan = Mock(return_value=[LocalAudio(path, "aax", "DEMO000001", "Book", None, 10)])
        client = Mock(**{"run.return_value": [{"title": "Chapter 1"}]})
        editor = SimpleNamespace(
            audible_original=False, book={"asin": "DEMO000001"}, account="fixture",
            frame=SimpleNamespace(tools=SimpleNamespace(scan=scan)), client=client, api={},
        )
        self.assertIsNone(BookEditor._audible_chapters(editor, [path], cancel))
        editor.audible_original = True
        self.assertIsNone(BookEditor._audible_chapters(editor, [path, path], cancel))
        scan.assert_not_called()
        self.assertEqual(BookEditor._audible_chapters(editor, [path], cancel), [{"title": "Chapter 1"}])
        editor.book["asin"] = "DEMO000002"
        self.assertIsNone(BookEditor._audible_chapters(editor, [path], cancel))
        client.run.assert_called_once_with(
            "chapters", asin="DEMO000001", account_id="fixture", options={}, cancel=cancel,
        )

import unittest
from copy import deepcopy
from functools import partial
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, call, patch

from downaudible_windows.state import DEFAULT_DOWNLOAD, DEFAULTS

try:
    import wx
    from downaudible_windows.app import MainFrame
    from downaudible_windows.transfer_views import (
        TransfersPanel,
        download_example_paths,
    )
except ModuleNotFoundError as error:
    if error.name not in {"wx", "markdown"}:
        raise
    MainFrame = None


@unittest.skipIf(MainFrame is None, "The application runtime includes wxPython and Markdown")
class DownloadWorkflowTests(unittest.TestCase):
    def test_download_missing_rechecks_before_selecting_books(self):
        frame = Mock(_closed=False)
        frame.queue.pending = False
        frame.library.active_account_id = "example"
        book = {"asin": "DEMO000001"}
        frame.library.missing_books.return_value = [book]

        for customizing in (False, True):
            with self.subTest(customizing=customizing):
                frame.reset_mock()
                MainFrame.request_missing_downloads(frame, customizing=customizing)
                frame.library.missing_books.assert_not_called()
                frame.recheck_saved_files.call_args.kwargs["on_complete"]()
                if customizing:
                    frame.review_download.assert_called_once_with([book], ensure_audio=True)
                else:
                    frame.confirm_bulk_download.assert_called_once_with([book], "Download Missing", ensure_audio=True)

    def test_download_missing_abandons_request_when_account_changes(self):
        frame = Mock(_closed=False)
        frame.queue.pending = False
        frame.library.active_account_id = "before"
        MainFrame.request_missing_downloads(frame)
        frame.library.active_account_id = "after"
        frame.recheck_saved_files.call_args.kwargs["on_complete"]()
        frame.library.missing_books.assert_not_called()

    def test_accepted_download_missing_enqueues_audio(self):
        book = {"asin": "DEMO000001"}
        frame = Mock()
        frame.downloadable_books.return_value = [book]
        frame.queue.pending = False
        dialog = MagicMock()
        dialog.__enter__.return_value.ShowModal.return_value = wx.ID_OK
        frame.bulk_download_dialog.return_value = dialog

        MainFrame.confirm_bulk_download(frame, [book], "Download Missing", ensure_audio=True)

        frame.enqueue_books.assert_called_once_with([book], {"downloadAudio": True})

    def test_download_choices_persist_without_restart_flags_and_roll_back_on_error(self):
        frame = Mock(settings=deepcopy(DEFAULTS))
        options = {**DEFAULT_DOWNLOAD, "downloadAudio": False, "downloadChapters": True, "restart": True,
                   "destination": "Selected Archive", "folder_template": "{author}/{title}"}
        self.assertTrue(MainFrame.save_download_choices(frame, options))
        frame.save_settings.assert_called_once()
        self.assertEqual(frame.settings["archive_root"], "Selected Archive")
        self.assertEqual(frame.settings["folder_template"], "{author}/{title}")
        self.assertFalse(frame.settings["download"]["downloadAudio"])
        self.assertTrue(frame.settings["download"]["downloadChapters"])
        self.assertNotIn("restart", frame.settings["download"])

        frame.save_settings.side_effect = OSError("Unable to write settings")
        before = deepcopy(frame.settings)
        self.assertFalse(MainFrame.save_download_choices(frame, {**options, "destination": "Another Archive"}))
        self.assertEqual(frame.settings, before)

    def test_preview_uses_selected_template_and_chapter_format(self):
        settings = deepcopy(DEFAULTS)
        settings["conversion"]["chapter_mode"] = "separate"
        book = {"title": "Example Book", "authors": ["Example Author"]}
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            options = {**DEFAULT_DOWNLOAD, "destination": str(root), "folder_template": "{format}/{title}",
                       "convert": True}
            original, chapter = map(Path, download_example_paths(settings, book, options))
            self.assertEqual(original, root / "aax" / "Example Book" / "Example Book.aax")
            self.assertEqual(chapter, root / "m4b" / "Example Book" / "Example Book - 01 - First Chapter.m4b")

            companion_only = {**options, "downloadAudio": False, "downloadPDF": True}
            self.assertEqual(download_example_paths(settings, book, companion_only),
                             [str(root / "extras" / "Example Book")])

    def test_activation_retry_rejects_invalid_input_and_targets_only_selected_aax_jobs(self):
        job = {"id": "aax", "kind": "Conversion", "source": "Book.aax", "status": "Failed"}
        local = {"id": "local", "kind": "Conversion", "source": "Other.m4b", "status": "Failed"}
        completed = {"id": "saved", "kind": "Conversion", "source": "Saved.aax", "status": "Completed"}
        panel = SimpleNamespace(frame=Mock(), shown_batch=lambda: {"id": "batch"},
                                selected=lambda: [job, local, completed],
                                can_retry_with_activation=TransfersPanel.can_retry_with_activation, retry_batch=Mock())
        panel.activation_dialog = partial(TransfersPanel.activation_dialog, panel)
        with patch("downaudible_windows.transfer_views.wx.PasswordEntryDialog") as password_dialog:
            dialog = password_dialog.return_value.__enter__.return_value
            dialog.ShowModal.side_effect = [wx.ID_OK, wx.ID_OK]
            dialog.GetValue.side_effect = ["not a code", " 1a2B3c4D "]
            TransfersPanel.retry_with_activation(panel)
        panel.frame.error.assert_called_once()
        panel.frame.runner.retry_activation_reference.assert_not_called()
        arguments, options = panel.retry_batch.call_args
        self.assertEqual(arguments, ("batch", {"aax"}))
        options["prepare_activation"]()
        panel.frame.runner.retry_activation_reference.assert_called_once_with("1a2B3c4D")

    def test_reveals_all_distinct_existing_selected_outputs_and_partial_folders(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            first, second, missing = (root / name for name in ("Book.m4b", "Picture.jpg", "Missing.m4b"))
            first.touch()
            second.touch()
            first_partial, second_partial = (root / name for name in ("Partial1", "Partial2"))
            for folder in (first_partial, second_partial):
                folder.mkdir()
            jobs = [{"files": [str(first), str(missing)], "partial": first_partial},
                    {"files": [str(first), str(second)], "partial": second_partial},
                    {"files": [str(second)], "partial": second_partial},
                    {"files": [str(missing)], "partial": None}]
            frame = Mock()
            frame.runner.has_partial.side_effect = lambda job, settings: job["partial"] is not None
            frame.runner.stage_for.side_effect = lambda job, settings: SimpleNamespace(path=job["partial"])
            panel = SimpleNamespace(frame=frame, selected=lambda: jobs, shown_batch=lambda: {"settings": {}})

            TransfersPanel.reveal(panel)
            self.assertEqual(frame.show_file.call_args_list, [call(first), call(second)])
            TransfersPanel.reveal_partial(panel)
            self.assertEqual(frame.open_file.call_args_list, [call(first_partial), call(second_partial)])

    def test_restart_selected_keyboard_shortcut_leaves_the_global_accelerator_alone(self):
        panel = SimpleNamespace(frame=SimpleNamespace(guard=lambda callback: callback()),
                                retry=Mock(), reveal=Mock(), reveal_partial=Mock(), copy_errors=Mock())
        event = Mock(**{"GetKeyCode.return_value": ord("T"), "ControlDown.return_value": True,
                        "ShiftDown.return_value": True, "AltDown.return_value": False})
        TransfersPanel._key(panel, event)
        panel.retry.assert_called_once_with(selected=True, restart=True)

        panel.retry.reset_mock()
        event.GetKeyCode.return_value = ord("R")
        event.AltDown.return_value = True
        TransfersPanel._key(panel, event)
        event.Skip.assert_called_once()
        panel.retry.assert_not_called()

import unittest
from dataclasses import replace
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, patch

from downaudible_windows.updater import Update

try:
    from downaudible_windows import app
except ModuleNotFoundError as error:
    if error.name != "wx":
        raise
    app = None


def dialog_reply(answer):
    dialog = MagicMock()
    dialog.__enter__.return_value.ShowModal.return_value = answer
    return dialog


@unittest.skipIf(app is None, "The Windows application runtime includes wxPython")
class UpdateFlowTests(unittest.TestCase):
    @staticmethod
    def frame(**values):
        settings = {"check_updates": False, "update_choice_made": False,
                    "install_updates": False, "setup_complete": True}
        return SimpleNamespace(
            settings=settings,
            _closed=False,
            _exit_without_saving=False,
            _staged_update=Path("Installer.exe"),
            _staged_release=None,
            update_publisher=Mock(return_value="CN=Fixture Publisher"),
            error=Mock(),
            **values,
        )

    def test_automatic_check_requires_post_setup_consent_and_remembers_decline(self):
        frame = self.frame(check_updates=Mock(), save_settings=Mock(), update_choice_dialog=Mock())
        frame.settings["setup_complete"] = False
        app.MainFrame.start_update_checks(frame)
        frame.update_choice_dialog.assert_not_called()
        frame.settings["setup_complete"] = True
        dialog = frame.update_choice_dialog.return_value = dialog_reply(app.wx.ID_NO)
        app.MainFrame.start_update_checks(frame)
        app.MainFrame.start_update_checks(frame)
        frame.update_choice_dialog.assert_called_once()
        dialog.__enter__.return_value.ShowModal.assert_called_once()
        self.assertTrue(frame.settings["update_choice_made"])
        self.assertFalse(frame.settings["check_updates"])
        frame.save_settings.assert_called_once()
        frame.check_updates.assert_not_called()

    def test_signed_manual_update_can_download_with_automatic_updates_off(self):
        update = SimpleNamespace(version="1.2.3", release_url="https://github.com/example")
        frame = self.frame(_download_update=Mock(), update_available_dialog=Mock(return_value=dialog_reply(app.wx.ID_OK)))
        app.MainFrame._offer_update(frame, update, "CN=Fixture Publisher")
        frame._download_update.assert_called_once_with(update, "CN=Fixture Publisher", restart=True)

    def test_reuses_a_stable_filename_only_for_the_same_release_metadata(self):
        previous = Update(
            version="0.10.0",
            architecture="arm64",
            release_url="https://github.com/example/releases/tag/V0.10.0",
            download_url="https://github.com/example/releases/download/V0.10.0/DownAudible-Windows-ARM64-Installer.exe",
            filename="DownAudible-Windows-ARM64-Installer.exe",
            size=10,
            digest="sha256:" + "0" * 64,
        )
        replacements = (
            replace(previous, version="0.11.0"),
            replace(previous, digest="sha256:" + "1" * 64),
        )
        with TemporaryDirectory() as directory:
            cached = Path(directory) / previous.filename
            cached.touch()
            frame = self.frame(set_status=Mock(), _update_staged=Mock())
            frame._staged_update = cached
            frame._staged_release = previous
            with patch.object(app, "Thread") as thread:
                app.MainFrame._download_update(frame, previous, "CN=Fixture Publisher", restart=True)
                frame._update_staged.assert_called_once_with(previous, cached, True)
                thread.assert_not_called()

            for update in replacements:
                with self.subTest(update=update), patch.object(app, "Thread") as thread:
                    frame._staged_update = cached
                    frame._staged_release = previous
                    frame._restart_for_update = True
                    frame._update_staged.reset_mock()
                    app.MainFrame._download_update(frame, update, "CN=Fixture Publisher", restart=True)
                    thread.return_value.start.assert_called_once()
                    self.assertIsNone(frame._staged_update)
                    self.assertIsNone(frame._staged_release)
                    self.assertFalse(frame._restart_for_update)
                    frame._update_staged.assert_not_called()

    def test_installer_handoff_requires_a_successful_queue_save(self):
        queue = Mock()
        queue.save.side_effect = OSError("write failed")
        frame = self.frame(queue=queue, resource_dir=Path("Install/Resources"))
        with (
            patch.dict(app.os.environ, {"DOWNAUDIBLE_LAUNCHER_PID": "32"}),
            patch.object(app, "schedule_verified_install") as schedule,
        ):
            self.assertFalse(app.MainFrame.install_on_exit(frame, restart=True))
            schedule.assert_not_called()
            frame.error.assert_called_once()

            calls = Mock()
            queue.save.side_effect = calls.save
            schedule.side_effect = calls.install
            self.assertTrue(app.MainFrame.install_on_exit(frame, restart=True))
            self.assertEqual([call[0] for call in calls.mock_calls], ["save", "install"])
            self.assertTrue(schedule.call_args.kwargs["restart"])

    def test_staged_manual_update_waits_for_the_transfer_queue(self):
        queue = Mock(active=True, pending=True, persistence_error=None)
        queue.snapshot.return_value = {"current": None}
        frame = self.frame(queue=queue, set_status=Mock(), Close=Mock(), transfers=Mock(), refresh_transfer_menu=Mock(),
                           _last_queue_summary=(), _exit_pending=False)
        app.MainFrame._update_staged(frame, SimpleNamespace(version="1.2.3"), Path("Update.exe"), True)
        app.MainFrame._refresh_queue(frame)
        frame.Close.assert_not_called()
        queue.active = False
        queue.pending = False
        app.MainFrame._refresh_queue(frame)
        frame.Close.assert_called_once()

    def test_failed_manual_handoff_keeps_downaudible_open(self):
        event = Mock()
        event.CanVeto.return_value = True
        frame = self.frame(queue=Mock(active=False, pending=False), library=Mock(), watcher=Mock(), update_timer=Mock(),
                           install_on_exit=Mock(return_value=False), _restart_for_update=True, _exit_pending=False)
        frame.library.save_columns.return_value = False
        app.MainFrame.on_close(frame, event)
        event.Veto.assert_called_once()
        event.Skip.assert_not_called()
        frame.queue.close.assert_not_called()

    def test_exit_without_saving_skips_a_staged_update(self):
        event = Mock()
        event.CanVeto.return_value = True
        frame = self.frame(queue=Mock(active=False, pending=False), library=Mock(), watcher=Mock(), update_timer=Mock(),
                           install_on_exit=Mock(), _restart_for_update=True, _exit_pending=True)
        frame.library.save_columns.return_value = False
        frame.Close = lambda: app.MainFrame.on_close(frame, event)
        app.MainFrame._finish_transfer_close(frame, save=False)
        frame.queue.save.assert_not_called()
        frame.install_on_exit.assert_not_called()
        event.Skip.assert_called_once()

"""Exercise Setup's rollback and retry paths without showing dialogs."""

from importlib.util import find_spec
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import TestCase, skipUnless
from unittest.mock import Mock, patch

from downaudible_windows.media import ConversionOptions, MediaError


@skipUnless(find_spec("wx"), "Settings forms require wxPython")
class SettingsPersistenceTests(TestCase):
    def setUp(self):
        from downaudible_windows import settings_views

        self.views = settings_views
        self.alert = self.enterContext(patch.object(settings_views.wx, "MessageBox"))
        self.settings = {"setup_complete": False, "folder_template": "{title}", "conversion": {"format": "m4b"}}
        self.frame = SimpleNamespace(settings=self.settings, save_settings=Mock())
        self.dialog = SimpleNamespace(
            frame=self.frame,
            panel=Mock(),
            index=4,
            configure=Mock(),
            EndModal=Mock(),
        )

    def test_rejected_setup_step_leaves_live_settings_and_bindings_intact(self):
        conversion = self.settings["conversion"]

        def apply():
            self.settings["folder_template"] = "../{title}"
            self.settings["new_value"] = True
            conversion["format"] = "mp3"
            raise ValueError("Check the folder template.")

        self.dialog.panel.apply.side_effect = apply
        self.views.SetupDialog.move(self.dialog, 1)
        self.alert.assert_called_once()
        self.assertEqual(self.settings["folder_template"], "{title}")
        self.assertNotIn("new_value", self.settings)
        self.assertIs(self.settings["conversion"], conversion)
        self.assertEqual(conversion, {"format": "m4b"})
        self.assertEqual(self.dialog.index, 4)
        self.frame.save_settings.assert_not_called()
        self.dialog.configure.assert_not_called()

    def test_failed_setup_finish_can_be_retried(self):
        self.frame.save_settings.side_effect = [PermissionError("Read-only profile"), None]
        self.views.SetupDialog.finish(self.dialog)
        self.alert.assert_called_once()
        self.assertFalse(self.settings["setup_complete"])
        self.dialog.EndModal.assert_not_called()

        self.views.SetupDialog.finish(self.dialog, help_requested=True)
        self.assertTrue(self.settings["setup_complete"])
        self.dialog.EndModal.assert_called_once_with(self.views.wx.ID_HELP)

    def test_view_toggle_preserves_the_saved_setting_when_writing_fails(self):
        from downaudible_windows.app import MainFrame

        command = Mock()
        frame = SimpleNamespace(settings={"show_sidebar": True}, _view_checks={"show_sidebar": command},
                                save_settings=Mock(side_effect=PermissionError("Read-only profile")), library=Mock())

        with self.assertRaises(PermissionError):
            MainFrame.toggle(frame, "show_sidebar")

        self.assertTrue(frame.settings["show_sidebar"])
        command.Check.assert_called_once_with(True)
        frame.library.update_status.assert_not_called()

    def test_back_from_skipped_setup_returns_to_the_page_that_was_visited(self):
        start = self.dialog.index
        self.dialog.history = [-1, 0, 1, 2, 3]
        self.views.SetupDialog.move(self.dialog, len(self.views.PAGES) - start)
        self.assertEqual(self.dialog.index, len(self.views.PAGES))
        self.views.SetupDialog.move(self.dialog, -1)
        self.assertEqual(self.dialog.index, start)

    def test_template_preview_uses_unapplied_files_and_conversion_controls(self):
        with TemporaryDirectory() as folder:
            archive = Path(folder).resolve()
            settings = {
                **self.settings, "archive_root": str(archive), "filename_case": "original",
                "chapter_filename_template": "{title}", "filename_spaces": "keep",
            }
            profile = settings["conversion"]
            mode = "separate"
            conversion = Mock()
            conversion.bindings = [
                (profile, "format", lambda: "mp3"),
                (profile, "chapter_mode", lambda: mode),
            ]
            conversion.values_for.side_effect = lambda data: self.views.Form.values_for(conversion, data)
            modal = SimpleNamespace(frame=SimpleNamespace(settings=settings), pages=[None] * len(self.views.PAGES))
            modal.pages[self.views.PAGES.index("Conversion")] = conversion
            page = SimpleNamespace(
                settings=settings,
                preview_conversion=lambda: self.views.SettingsDialog.conversion_values(modal),
                bindings=[
                    (settings, "folder_template", lambda: r"{format}\{author}"),
                    (settings, "chapter_filename_template", lambda: "{chapterNumber} {chapter}"),
                    (settings, "filename_spaces", lambda: "underscore"),
                    (settings, "filename_case", lambda: "uppercase"),
                    (settings, "filename_template", lambda: "{asin} {title}"),
                ],
            )
            page.values_for = lambda data: self.views.Form.values_for(page, data)

            self.views.SettingsPage.preview_files(page)
            self.assertIn(str(archive / "MP3" / "EXAMPLE_AUTHOR" / "01_THE_BEGINNING.mp3"),
                          self.alert.call_args.args[0])
            mode = "single"
            self.views.SettingsPage.preview_files(page)
            self.assertIn(str(archive / "MP3" / "EXAMPLE_AUTHOR" / "B000000001_DEMO_BOOK.mp3"),
                          self.alert.call_args.args[0])
            self.assertEqual(settings["folder_template"], "{title}")
            self.assertEqual(settings["chapter_filename_template"], "{title}")
            self.assertEqual(profile, {"format": "m4b"})


class ConversionPreferenceTests(TestCase):
    def test_rejects_impossible_explicit_encoding_combinations(self):
        for options in (
            ConversionOptions(format="mp3", bitrate=320, sample_rate=16000),
            ConversionOptions(format="m4b", bitrate=128, sample_rate=8000, channels=1),
        ):
            with self.subTest(options=options):
                self.assertTrue(options.has_incompatible_bitrate)
                with self.assertRaisesRegex(MediaError, "lower bitrate or a higher sample rate"):
                    options.validate()

    def test_keeps_source_dependent_and_variable_bitrate_choices(self):
        for options in (
            ConversionOptions(format="m4b", bitrate=128, sample_rate=8000),
            ConversionOptions(format="mp3", bitrate=320, sample_rate=16000, mp3_bitrate_mode="variable"),
        ):
            with self.subTest(options=options):
                self.assertFalse(options.has_incompatible_bitrate)
                options.validate()

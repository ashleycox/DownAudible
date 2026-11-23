import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, call, patch

try:
    from downaudible_windows import audible_dialogs
    from downaudible_windows.library import LibraryPanel
    from downaudible_windows.refusal import RetryAfter
except ModuleNotFoundError as error:
    if error.name != "wx":
        raise
    audible_dialogs = None


@unittest.skipIf(audible_dialogs is None, "The Windows application runtime includes wxPython")
class SignInDialogTests(unittest.TestCase):
    @staticmethod
    def dialog():
        dialog = Mock()
        dialog.working = False
        dialog.browser_attempt = None
        dialog.cancel = Event()
        dialog.library.frame.demo = False
        dialog.get_marketplace.return_value = "uk"
        dialog.legacy.GetValue.return_value = False
        dialog.method.GetSelection.return_value = 0
        dialog.android_source_id = None
        dialog.fixed_marketplace = False
        dialog.submit.IsEnabled.return_value = True
        dialog.reset_browser.side_effect = lambda: audible_dialogs.SignInDialog.reset_browser(dialog)
        return dialog

    def test_reopening_sign_in_page_reuses_attempt_until_start_again(self):
        dialog = self.dialog()
        first = {"url": "https://example.com/sign-in/first", "serial": "first", "verifier": "first"}
        second = {"url": "https://example.com/sign-in/second", "serial": "second", "verifier": "second"}
        dialog.client.run.side_effect = (first, second)

        def deliver(_owner, work, success, *, done, cancel):
            result = work()
            done()
            success(result)

        with (
            patch.object(audible_dialogs, "run_async", side_effect=deliver),
            patch.object(audible_dialogs, "open_browser") as browser,
        ):
            audible_dialogs.SignInDialog.open_browser(dialog)
            audible_dialogs.SignInDialog.open_browser(dialog)
            dialog.client.run.assert_called_once_with(
                "beginSignIn", marketplace="uk", legacyUsername=False, cancel=dialog.cancel
            )
            self.assertEqual(dialog.browser_attempt, (("uk", False, False), first))

            dialog.reset_browser()
            audible_dialogs.SignInDialog.open_browser(dialog)

        self.assertEqual(dialog.client.run.call_count, 2)
        self.assertEqual(dialog.browser_attempt, (("uk", False, False), second))
        self.assertEqual(browser.call_args_list, [call(first["url"]), call(first["url"]), call(second["url"])])

    def test_invalid_address_keeps_attempt_but_failed_registration_restarts(self):
        dialog = self.dialog()
        attempt = (("uk", False, False), {"serial": "fixture-serial", "verifier": "fixture-verifier"})
        dialog.browser_attempt = attempt
        dialog.redirect.GetValue.return_value = "https://example.com/fixture-redirect"

        with (
            patch.object(audible_dialogs, "run_async") as submit,
            patch.object(audible_dialogs, "show_error") as display_error,
        ):
            audible_dialogs.SignInDialog.sign_in(dialog)
            handler = submit.call_args.kwargs["failure"]
            handler(audible_dialogs.AudibleError("invalidRedirect"))
            self.assertEqual(dialog.browser_attempt, attempt)

            handler(audible_dialogs.AudibleError("signInFailed"))
            self.assertIsNone(dialog.browser_attempt)
            dialog.redirect.ChangeValue.assert_called_once_with("")
            self.assertEqual(display_error.call_count, 2)

    def test_browser_launch_failure_offers_to_copy_same_sign_in_link(self):
        dialog = self.dialog()
        attempt = {"url": "https://example.com/sign-in"}
        dialog.browser_attempt = (("uk", False, False), attempt)

        with patch.object(audible_dialogs, "open_browser", return_value=False):
            audible_dialogs.SignInDialog.open_browser(dialog)

        dialog.offer_to_copy_sign_in_link.assert_called_once_with(attempt["url"])
        self.assertEqual(dialog.browser_attempt, (("uk", False, False), attempt))
        dialog.client.run.assert_not_called()

    def test_pressing_enter_again_while_signing_in_does_not_resubmit(self):
        dialog = self.dialog()
        dialog.working = True
        with patch.object(audible_dialogs, "run_async") as submit:
            audible_dialogs.SignInDialog.sign_in(dialog)

        submit.assert_not_called()

    def test_credential_sign_in_clears_password_before_sending_it(self):
        dialog = self.dialog()
        dialog.method.GetSelection.return_value = 1
        dialog.user.GetValue.return_value = "  email@example.com  "
        dialog.password.GetValue.return_value = "password12345"

        def deliver(_owner, work, _success, **_callbacks):
            dialog.password.Clear.assert_called_once()
            work()

        with patch.object(audible_dialogs, "run_async", side_effect=deliver):
            audible_dialogs.SignInDialog.sign_in(dialog)

        dialog.client.run.assert_called_once_with(
            "credentialSignIn",
            marketplace="uk",
            legacyUsername=False,
            username="email@example.com",
            password="password12345",
            respond=dialog.respond,
            cancel=dialog.cancel,
        )

    def test_reconnecting_preserves_account_and_marketplace(self):
        dialog = self.dialog()
        dialog.reconnecting = True
        dialog.fixed_marketplace = True
        dialog.method.GetSelection.return_value = 1
        dialog.legacy.GetValue.return_value = True

        audible_dialogs.SignInDialog.update_actions(dialog)

        dialog.name.Enable.assert_called_once_with(False)
        dialog.marketplace.Enable.assert_called_once_with(False)
        dialog.user_label.SetLabel.assert_called_once_with("Audible Username")
        dialog.user.Enable.assert_called_once_with(True)

    def test_android_registration_passes_browser_context_and_previous_session(self):
        dialog = self.dialog()
        dialog.method.GetSelection.return_value = audible_dialogs.ANDROID_BROWSER
        dialog.legacy.GetValue.return_value = True
        dialog.android_source_id = "original-profile"
        dialog.account_id = "new-profile"
        dialog.name.GetValue.return_value = "Account (Android)"
        dialog.client.session.return_value = "original-session"
        dialog.client.run.side_effect = (
            {"url": "https://example.com/sign-in", "serial": "serial", "verifier": "verifier",
             "registrationContext": "context"},
            {"session": "fresh-session"},
        )

        def deliver(_owner, work, success, *, done, **_callbacks):
            result = work()
            done()
            success(result)

        with (patch.object(audible_dialogs, "run_async", side_effect=deliver),
              patch.object(audible_dialogs, "open_browser"), patch.object(audible_dialogs, "finish_dialog")):
            audible_dialogs.SignInDialog.open_browser(dialog)
            dialog.redirect.GetValue.return_value = "https://example.com/callback"
            audible_dialogs.SignInDialog.sign_in(dialog)

        dialog.client.session.assert_called_once_with("original-profile")
        self.assertEqual(dialog.client.run.call_args_list, [
            call("beginSignIn", marketplace="uk", legacyUsername=False, cancel=dialog.cancel, deviceProfile="android"),
            call("completeSignIn", marketplace="uk", legacyUsername=False, redirect="https://example.com/callback",
                 serial="serial", verifier="verifier", deviceProfile="android", registrationContext="context",
                 previousSession="original-session", respond=None, cancel=dialog.cancel),
        ])
        dialog.library.save_account.assert_called_once_with("new-profile", "Account (Android)", "uk", "fresh-session",
                                                           previous_registration=("original-profile", "original-session"))

    def test_wrong_account_restarts_android_sign_in_without_saving(self):
        dialog = self.dialog()
        dialog.method.GetSelection.return_value = audible_dialogs.ANDROID_BROWSER
        dialog.android_source_id = "original-profile"
        dialog.browser_attempt = (("uk", False, True), {"serial": "serial", "verifier": "verifier",
                                                        "registrationContext": "context"})
        dialog.redirect.GetValue.return_value = "https://example.com/callback"
        with (patch.object(audible_dialogs, "run_async") as submit,
              patch.object(audible_dialogs, "show_error") as display_error):
            audible_dialogs.SignInDialog.sign_in(dialog)
            submit.call_args.kwargs["failure"](audible_dialogs.AudibleError("accountMismatch"))
        self.assertIsNone(dialog.browser_attempt)
        dialog.library.save_account.assert_not_called()
        display_error.assert_called_once()


@unittest.skipIf(audible_dialogs is None, "The Windows application runtime includes wxPython")
class ImportDialogTests(unittest.TestCase):
    def test_chooses_configured_default_even_when_it_is_not_first(self):
        profiles = [{"name": "Other"}, {"name": "Main", "isDefault": True}]
        importer = audible_dialogs.ImportAccountDialog
        dialog = SimpleNamespace(path=Mock(), mode=Mock(), client=Mock(), profile=Mock(), status=Mock(),
                                 invalidate_source=Mock(), sync_profile=Mock(), update_actions=Mock(),
                                 CLI_PROFILE=importer.CLI_PROFILE, AUTH_FILE=importer.AUTH_FILE,
                                 OPEN_AUDIBLE=importer.OPEN_AUDIBLE)
        dialog.path.GetValue.return_value = "sample-config.toml"
        dialog.mode.GetSelection.return_value = 0
        dialog.client.run.return_value = profiles

        def deliver(_owner, work, success, **_callbacks):
            success(work())

        with patch.object(audible_dialogs, "run_async", side_effect=deliver):
            importer.load_profiles(dialog)

        dialog.profile.SetSelection.assert_called_once_with(1)
        dialog.sync_profile.assert_called_once_with()
        self.assertEqual(dialog.profiles, profiles)


@unittest.skipIf(audible_dialogs is None, "The Windows application runtime includes wxPython")
class AccountRegistrationTests(unittest.TestCase):
    @patch("downaudible_windows.audible._dpapi", side_effect=lambda contents, **options: contents[::-1])
    def test_reconnect_preserves_profile_and_separate_registration_starts_clean(self, _dpapi):
        from downaudible_windows.audible import AudibleClient

        with TemporaryDirectory() as temporary:
            client = AudibleClient(Path(temporary), Path(temporary))
            source = {"id": "source", "name": "My Account", "marketplace": "uk", "widevine_enabled": True}
            matches = {"source": {"DEMO000001": ["example.m4b"]}}
            frame = SimpleNamespace(settings={"audible_accounts": [source], "audible_account": "source", "matches": matches},
                                    save_settings=Mock())
            panel = SimpleNamespace(frame=frame, accounts=[source], client=client, can_remove_accounts=Mock(return_value=True),
                                    _reload_account=Mock(), clear_catalogue=Mock())
            panel._persist_accounts = lambda accounts, selected: LibraryPanel._persist_accounts(panel, accounts, selected)
            client.save_session("source", "old-session")
            with client.widevine_change("source", "fixture-cdm"):
                pass

            LibraryPanel.save_account(panel, "duplicate", "My Account (Android)", "uk", "separate-session",
                                      previous_registration=("source", "old-session"))
            self.assertEqual(frame.settings["audible_accounts"][0], source)
            self.assertEqual(frame.settings["audible_account"], "duplicate")
            self.assertEqual(frame.settings["matches"], matches)
            self.assertEqual(client.session("source"), "old-session")
            self.assertEqual(client.widevine_cdm("source"), "fixture-cdm")
            self.assertEqual(client.widevine_cdm("duplicate"), "fixture-cdm")
            self.assertNotIn("widevine_enabled", frame.settings["audible_accounts"][1])

            panel.accounts = frame.settings["audible_accounts"]
            frame.save_settings.side_effect = OSError("Fixture settings failure")
            with self.assertRaises(audible_dialogs.AudibleError):
                LibraryPanel.save_account(panel, "failed", "My Account (Android)", "uk", "failed-session",
                                          previous_registration=("source", "old-session"))
            self.assertFalse(client.has_session("failed"))
            self.assertIsNone(client.widevine_cdm("failed"))
            self.assertEqual(frame.settings["audible_account"], "duplicate")
            frame.save_settings.side_effect = None

            LibraryPanel.save_account(panel, "source", "My Account", "uk", "replacement-session",
                                      previous_registration=("source", "old-session"))
            self.assertEqual(frame.settings["audible_accounts"][0], {"id": "source", "name": "My Account", "marketplace": "uk"})
            self.assertEqual(frame.settings["audible_account"], "source")
            self.assertEqual(frame.settings["matches"], matches)
            self.assertEqual(client.session("source"), "replacement-session")
            self.assertEqual(client.session("duplicate"), "separate-session")
            self.assertEqual(client.widevine_cdm("source"), "fixture-cdm")

            panel.accounts = frame.settings["audible_accounts"]
            LibraryPanel.save_account(panel, "source", "My Account", "uk", "unverified-session")
            self.assertIsNone(client.widevine_cdm("source"))
            self.assertEqual(client.widevine_cdm("duplicate"), "fixture-cdm")
            panel.clear_catalogue.assert_called_once_with("source")


@unittest.skipIf(audible_dialogs is None, "The Windows application runtime includes wxPython")
class WidevineDialogTests(unittest.TestCase):
    def test_explicit_enable_provisions_once_and_disable_uses_no_network(self):
        dialog = Mock(working=False, enabled=False, account_id="demo-account")
        dialog.library.client.provision_widevine.return_value = "ZGVtbw=="
        with patch.object(audible_dialogs, "run_async") as run, patch.object(audible_dialogs, "finish_dialog"):
            audible_dialogs.WidevineDialog.change(dialog, None)
            audible_dialogs.WidevineDialog.change(dialog, None)
            run.assert_called_once()
            _, work, success = run.call_args.args
            result = work()
            run.call_args.kwargs["done"]()
            success(result)
            dialog.library.client.provision_widevine.assert_called_once_with("demo-account")
            dialog.library.set_widevine.assert_called_once_with("demo-account", True, "ZGVtbw==")

            dialog.enabled = True
            dialog.library.set_widevine.reset_mock()
            audible_dialogs.WidevineDialog.change(dialog, None)
            dialog.library.set_widevine.assert_called_once_with("demo-account", False, None)
            run.assert_called_once()


@unittest.skipIf(audible_dialogs is None, "The Windows application runtime includes wxPython")
class DeviceRegistrationTests(unittest.TestCase):
    def test_device_dialog_requires_matching_marketplace_and_saved_session(self):
        dialog = Mock()
        account = {"id": "profile", "marketplace": "uk"}
        dialog.selected.return_value = account
        dialog.library.client.session.return_value = "sample-session"
        with (patch.object(audible_dialogs, "run_async") as run,
              patch.object(audible_dialogs, "show_error") as error,
              patch.object(audible_dialogs, "DeviceRegistrationDialog") as device):
            audible_dialogs.AccountsDialog.device_registration(dialog)
            _owner, work, finish = run.call_args.args
            work()
            dialog.library.client.run.assert_called_once_with("deviceRegistration", session="sample-session")
            finish({"marketplace": "us"})
            device.assert_not_called()
            self.assertEqual(error.call_args.args[1].code, "accountVerification")
            dialog.library.client.session.return_value = "different-session"
            finish({"marketplace": "uk"})
            device.assert_not_called()
            dialog.library.client.session.return_value = "sample-session"
            finish({"marketplace": "uk"})
            device.assert_called_once()

    def test_deregister_requires_confirmation_and_server_success(self):
        dialog = Mock(working=False, account_id="profile", session="sample-session")
        dialog.library.can_remove_accounts.return_value = True
        dialog.library.client.session.return_value = dialog.session
        message = MagicMock()
        message.__enter__.return_value = message
        message.ShowModal.side_effect = (audible_dialogs.wx.ID_NO, audible_dialogs.wx.ID_YES)
        with (patch.object(audible_dialogs.wx, "MessageDialog", return_value=message),
              patch.object(audible_dialogs, "run_async") as run, patch.object(audible_dialogs, "finish_dialog")):
            audible_dialogs.DeviceRegistrationDialog.deregister(dialog)
            run.assert_not_called()
            audible_dialogs.DeviceRegistrationDialog.deregister(dialog)
            _owner, work, finish = run.call_args.args
            dialog.library.client.run.return_value = False
            with self.assertRaises(audible_dialogs.AudibleError) as error:
                work()
            self.assertEqual(error.exception.code, "deviceDeregistration")
            dialog.library.sign_out.assert_not_called()
            dialog.library.client.run.return_value = True
            finish(work())
            dialog.library.client.run.assert_called_with("deregisterDevice", session="sample-session", confirmed=True)
            dialog.library.sign_out.assert_called_once_with("profile")


@unittest.skipIf(audible_dialogs is None, "The Windows application runtime includes wxPython")
class LibraryOfferTests(unittest.TestCase):
    def test_quality_audit_and_queue_use_effective_format_and_best(self):
        library = Mock(books=[])
        account = {"id": "profile", "widevine_enabled": True}
        library.choose_insight_account.return_value = account
        with patch("downaudible_windows.insights.show_quality_audit") as show:
            for mode, cdm, preferred in (("preferAAX", None, False), ("preferAAX", "fixture", True),
                                         ("aaxOnly", "fixture", False)):
                with self.subTest(mode=mode, cdm=cdm):
                    library.client.widevine_cdm.return_value = cdm
                    library.title_offer_options.return_value = {"format": mode, "quality": "standard", "preferWidevine": True}
                    LibraryPanel.show_quality_audit(library)
                    options, queue = show.call_args.args[-2:]
                    self.assertEqual(options, {"format": mode, "quality": "best", "preferWidevine": preferred})
                    queue([])
                    self.assertEqual(library.frame.enqueue_books.call_args.kwargs["upgrade"], options)

    def test_manual_refresh_respects_profile_cooldown_and_background_waits_for_transfers(self):
        account = {"id": "profile", "name": "Sample", "marketplace": "uk"}
        library = Mock(accounts=[account], active_account_id=account["id"], _refresh_request=None, all_accounts=False)
        library.is_signed_in.return_value = True
        library.displayed_accounts.return_value = [account]
        library.frame.queue.pending = True
        with patch("downaudible_windows.library.run_async") as run:
            LibraryPanel.refresh(library, all_accounts=True, background=True)
            run.assert_not_called()
            library.frame.runner.refusals.check.side_effect = RetryAfter(1_750_000_000, "Too many requests.")
            LibraryPanel.refresh(library)
        result, failures = run.call_args.args[1]()
        self.assertEqual(result, [])
        self.assertIn("Try again after", failures[0])
        library.client.run.assert_not_called()

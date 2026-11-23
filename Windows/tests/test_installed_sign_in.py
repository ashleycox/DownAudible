"""Drive native sign-in dialogs and the bundled helper with offline account fixtures."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from time import monotonic, sleep
from types import SimpleNamespace
from unittest.mock import patch

from downaudible_windows.state import read_json

RESOURCES = Path(sys.executable).resolve().parent.parent / "resources"
PACKAGED = os.name == "nt" and (RESOURCES / "Audible" / "audible_helper.py").is_file()
FIXTURE_CODE = "synthetic-authorization-code"
FIXTURE_EMAIL = "reader@example.com"
FIXTURE_PASSWORD = "example-password"
FIXTURE_OTP = "621540"


def run_fixture_helper():
    import audible_helper as helper

    original_execute = helper.execute

    async def execute(request):
        if request["command"] == "library":
            session = json.loads(request["session"])
            assert session["mode"] in {"browser", "credentials"}
            return [{"asin": "DEMO000001", "title": "Signed-in fixture book"}]
        return await original_execute(request)

    def register(**fields):
        assert fields["authorization_code"] == FIXTURE_CODE
        assert len(fields["code_verifier"]) >= 43
        return {"mode": "browser"}

    def credentials(**fields):
        assert fields["username"] == FIXTURE_EMAIL
        assert fields["password"] == FIXTURE_PASSWORD
        assert fields["otp_callback"]() == FIXTURE_OTP
        return SimpleNamespace(to_dict=lambda: {"mode": "credentials"})

    with (
        patch.object(helper, "execute", execute),
        patch.object(helper, "register", register),
        patch.object(helper.audible.Authenticator, "from_login", credentials),
        patch.object(
            helper.audible.Authenticator,
            "from_dict",
            lambda data: SimpleNamespace(to_dict=lambda: data),
        ),
    ):
        helper.main()


@unittest.skipUnless(
    PACKAGED, "Run with the installed Windows Python and Audible helper"
)
class InstalledSignInTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import wx

        cls.wx = wx
        cls.application = wx.GetApp() or wx.App(False)

    def setUp(self):
        from downaudible_windows import audible_dialogs
        from downaudible_windows.app import MainFrame

        self.dialogs = audible_dialogs
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.profile = Path(directory.name)
        self.frame = MainFrame(self.profile, RESOURCES, test_mode=True)
        self.addCleanup(self.frame.Close, True)
        self.client = self.frame.library.client
        helper = [
            sys.executable,
            "-X",
            "utf8",
            str(Path(__file__).resolve()),
            "--fixture-helper",
        ]
        self.enterContext(
            patch.object(self.client, "_command_line", return_value=helper)
        )
        self.errors = self.enterContext(patch.object(self.dialogs, "show_error"))
        self.dialog = self.dialogs.SignInDialog(self.frame, self.frame.library)
        self.addCleanup(self.close_dialog)
        self.account = self.dialog.account_id
        self.dialog.Show()

    def close_dialog(self):
        if self.dialog and not self.dialog.IsBeingDeleted():
            self.dialog.cancel.set()
            self.dialog.Destroy()

    def wait_until(self, condition):
        deadline = monotonic() + 12
        while monotonic() < deadline:
            self.wx.YieldIfNeeded()
            if self.errors.called:
                self.fail(
                    f"Unexpected sign-in error {self.errors.call_args.args[1].code}"
                )
            if condition():
                return
            sleep(0.025)
        self.fail("The Windows sign-in fixture did not complete")

    def verify_session(self, mode):
        self.wait_until(lambda: bool(self.frame.library.books))
        self.assertEqual(self.frame.library.books[0]["title"], "Signed-in fixture book")
        self.assertEqual(json.loads(self.client.session(self.account))["mode"], mode)
        settings = read_json(self.profile / "Settings.json")
        self.assertEqual(settings["audible_account"], self.account)
        self.assertTrue((self.profile / "Accounts" / f"{self.account}.dpapi").is_file())

    def test_browser_reopen_and_submit_save_an_account(self):
        with patch.object(self.dialogs, "open_browser", return_value=True) as opened:
            self.dialog.open_browser()
            self.wait_until(lambda: opened.call_count == 1)
            attempt = self.dialog.browser_attempt
            self.dialog.open_browser()
            self.wait_until(lambda: opened.call_count == 2)
            self.assertTrue(
                self.dialog.browser_attempt == attempt,
                "Reopening must retain the original browser attempt",
            )
            self.assertTrue(
                opened.call_args_list[0] == opened.call_args_list[1],
                "Reopening must open the same sign-in page",
            )
        self.dialog.redirect.SetValue(
            f"https://www.amazon.co.uk/ap/maplanding?openid.oa2.authorization_code={FIXTURE_CODE}"
        )
        self.dialog.sign_in()
        self.verify_session("browser")

    def test_credentials_otp_and_library_load_save_an_account(self):
        original_show = self.dialogs.VerificationDialog.ShowModal
        verification_prompts = []

        def enter_code(dialog):
            verification_prompts.append(dialog.answer.GetName())

            def accept():
                dialog.answer.SetValue(FIXTURE_OTP)
                dialog.EndModal(self.wx.ID_OK)

            self.wx.CallAfter(accept)
            return original_show(dialog)

        self.dialog.method.SetSelection(1)
        self.dialog.sync_method()
        self.dialog.user.SetValue(FIXTURE_EMAIL)
        self.dialog.password.SetValue(FIXTURE_PASSWORD)
        with patch.object(self.dialogs.VerificationDialog, "ShowModal", enter_code):
            self.dialog.sign_in()
            self.verify_session("credentials")
        self.assertEqual(len(verification_prompts), 1)


if __name__ == "__main__":
    if sys.argv[1:] == ["--fixture-helper"]:
        run_fixture_helper()
    else:
        unittest.main()

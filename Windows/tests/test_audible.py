import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from downaudible_windows.audible import (
    LEGACY_MARKETPLACES,
    MARKETPLACES,
    AudibleClient,
    AudibleError,
    auth_file_path,
)


class AudibleClientTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.client = AudibleClient(self.root, self.root)

    def run_fixture(self, fixture, command, **kwargs):
        helper_dir = self.root / "Audible"
        helper_dir.mkdir(exist_ok=True)
        (helper_dir / "audible_helper.py").write_text(fixture, encoding="utf-8")
        with patch.dict("os.environ", {"DOWNAUDIBLE_PYTHON": sys.executable}):
            return self.client.run(command, **kwargs)

    def test_streams_progress_and_interactive_reply(self):
        progress = []
        responses = []
        fixture = """
import json
import sys
request = json.loads(sys.stdin.readline())
print(json.dumps({'progress': 0.5}), flush=True)
print(json.dumps({'signInChallenge': {'kind': 'otp'}}), flush=True)
reply = json.loads(sys.stdin.readline())
assert request['username'] == 'example@example.com'
assert len(sys.argv) == 1
print(json.dumps({'result': reply}), flush=True)
"""

        def respond(challenge):
            responses.append(challenge)
            return "123456"

        result = self.run_fixture(fixture, "credentialSignIn", username="example@example.com",
                                  password="example password", progress=progress.append, respond=respond)
        self.assertEqual(result, {"answer": "123456"})
        self.assertEqual(progress, [0.5])
        self.assertEqual(responses, [{"kind": "otp"}])

    def test_error_output_is_a_safe_message(self):
        fixture = """
import sys
sys.stdin.readline()
print('credential data should never appear', file=sys.stderr)
print('{"error":"authorization"}')
"""
        with self.assertRaises(AudibleError) as raised:
            self.run_fixture(fixture, "library", session='{"fixture":true}')
        self.assertEqual(raised.exception.code, "authorization")
        self.assertNotIn("credential data", str(raised.exception))

    def test_can_cancel_a_running_helper(self):
        fixture = """
import sys
import time
sys.stdin.readline()
print('{"progress":0.1}', flush=True)
time.sleep(60)
"""
        cancel = threading.Event()
        with self.assertRaises(AudibleError) as raised:
            self.run_fixture(fixture, "library", session='{"fixture":true}', cancel=cancel,
                             progress=lambda value: cancel.set())
        self.assertEqual(raised.exception.code, "cancelled")

    def test_demo_does_not_persist_sessions(self):
        client = AudibleClient(self.root, self.root, demo=True)
        self.assertTrue(client.has_session("demo-account"))
        client.remove_session("demo-account")
        self.assertFalse(client.has_session("demo-account"))
        client.save_session("demo-account", "unused")
        self.assertTrue(client.has_session("demo-account"))
        self.assertFalse((self.root / "Accounts").exists())

    def test_auth_file_path_round_trip(self):
        path = self.root / "an audible account.json"
        self.assertEqual(auth_file_path(path.as_uri()), path)

    def test_session_path_cannot_escape_account_directory(self):
        with self.assertRaises(AudibleError):
            self.client.session("../config")

    @patch("downaudible_windows.audible._dpapi", side_effect=lambda contents, **options: contents[::-1])
    def test_session_write_rolls_back_when_settings_fail(self, _dpapi):
        def fail_to_save(account_id, session):
            with self.assertRaises(OSError):
                with self.client.session_change(account_id, session):
                    raise OSError("Settings could not be saved")

        account_id = "current-account"
        earlier = '{"previous":true}'
        self.client.save_session(account_id, earlier)
        previous_bytes = (self.root / "Accounts" / f"{account_id}.dpapi").read_bytes()
        for replacement in ('{"replacement":true}', None):
            with self.subTest(replacement=replacement):
                fail_to_save(account_id, replacement)
                self.assertEqual(self.client.session(account_id), earlier)
                self.assertEqual((self.root / "Accounts" / f"{account_id}.dpapi").read_bytes(), previous_bytes)
        fail_to_save("new-account", '{"new":true}')
        self.assertFalse(self.client.has_session("new-account"))

    @patch("downaudible_windows.audible._dpapi", side_effect=lambda contents, **options: contents[::-1])
    def test_verified_reconnect_or_duplicate_requires_current_source_session(self, _dpapi):
        original = "original-account"
        signed_in = '{"original":true}'
        replacement = '{"android":true}'
        self.client.save_session(original, signed_in)
        for target in (original, "new-account"):
            with self.subTest(target=target):
                with (self.assertRaises(AudibleError) as failure,
                      self.client.session_change(target, replacement, previous_registration=(original, "stale"))):
                    self.fail("A stale registration reached settings persistence")
                self.assertEqual(failure.exception.code, "accountVerification")
        self.assertEqual(self.client.session(original), signed_in)
        self.assertFalse(self.client.has_session("new-account"))
        with self.client.session_change("new-account", replacement, previous_registration=(original, signed_in)):
            self.assertEqual(self.client.session("new-account"), replacement)
        self.assertEqual(self.client.session(original), signed_in)

    @patch("downaudible_windows.audible._dpapi", side_effect=lambda contents, **options: contents[::-1])
    def test_widevine_is_provisioned_only_with_consent_and_kept_separate(self, _dpapi):
        account = "current-account"
        session = '{"fixture":true}'
        self.client.save_session(account, session)
        with patch.object(self.client, "run", return_value={"cdm": "Zml4dHVyZQ=="}) as run:
            cdm = self.client.provision_widevine(account)
            run.assert_called_once_with("provisionWidevine", session=session, consent=True)
        with self.client.widevine_change(account, cdm):
            self.assertEqual(self.client.widevine_cdm(account), cdm)
        with patch.object(self.client, "run") as run:
            self.assertIsNone(self.client.provision_widevine(account))
            run.assert_not_called()
        self.assertIsNone(self.client.widevine_cdm("another-account"))
        with self.client.widevine_change(account, None):
            self.assertIsNone(self.client.widevine_cdm(account))
        self.assertEqual(self.client.session(account), session)

    @patch("downaudible_windows.audible._dpapi", side_effect=lambda contents, **options: contents[::-1])
    def test_widevine_provisioning_requires_the_original_session(self, _dpapi):
        account = "current-account"
        self.client.save_session(account, '{"original":true}')

        def changed_session(command, **fields):
            self.client.save_session(account, '{"different":true}')
            return {"cdm": "Zml4dHVyZQ=="}

        with patch.object(self.client, "run", side_effect=changed_session), self.assertRaises(AudibleError) as error:
            self.client.provision_widevine(account)
        self.assertEqual(error.exception.code, "widevineProvision")
        self.assertIsNone(self.client.widevine_cdm(account))

    @unittest.skipUnless(sys.platform == "win32", "DPAPI requires Windows")
    def test_dpapi_session_persistence(self):
        session = '{"sample":"example session"}'
        self.client.save_session("fake-test", session)
        encrypted = (self.root / "Accounts" / "fake-test.dpapi").read_bytes()
        self.assertNotIn(session.encode(), encrypted)
        other = AudibleClient(self.root, self.root)
        self.assertEqual(other.session("fake-test"), session)
        self.client.remove_session("fake-test")
        self.assertFalse(other.has_session("fake-test"))

    @unittest.skipUnless(sys.platform == "win32", "The bundled helper requires Windows")
    def test_packaged_sign_in_helper_prepares_browser_attempts(self):
        resources = Path(sys.executable).parent.parent / "resources"
        if not (resources / "Audible" / "audible_helper.py").is_file():
            self.skipTest("Run with the Windows package's private Python interpreter")
        client = AudibleClient(resources, self.root)
        cancel = threading.Event()
        deadline = threading.Timer(60, cancel.set)
        deadline.daemon = True
        deadline.start()
        self.addCleanup(deadline.cancel)
        with patch.dict("os.environ", {"DOWNAUDIBLE_PYTHON": sys.executable}):
            for marketplace in MARKETPLACES:
                modes = (False, True) if marketplace in LEGACY_MARKETPLACES else (False,)
                for legacy in modes:
                    with self.subTest(marketplace=marketplace, legacy=legacy):
                        attempt = client.run(
                            "beginSignIn", marketplace=marketplace, legacyUsername=legacy, cancel=cancel,
                        )
                        page = urlsplit(attempt["url"])
                        self.assertEqual(page.scheme, "https")
                        self.assertTrue(page.hostname.startswith("www.audible." if legacy else "www.amazon."))
                        self.assertEqual(page.path, "/ap/signin")
                        query = parse_qs(page.query)
                        self.assertEqual(query["openid.return_to"], [f"https://{page.hostname}/ap/maplanding"])
                        self.assertTrue(attempt["serial"])
                        self.assertTrue(attempt["verifier"])
            with self.assertRaises(AudibleError) as raised:
                client.run(
                    "completeSignIn",
                    marketplace="uk",
                    legacyUsername=False,
                    redirect="https://example.com/ap/maplanding?openid.oa2.authorization_code=fixture",
                    serial="fixture-serial",
                    verifier="fixture-verifier",
                    cancel=cancel,
                )
            self.assertEqual(raised.exception.code, "invalidRedirect")

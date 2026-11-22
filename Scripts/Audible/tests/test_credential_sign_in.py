"""Exercise the credential sign-in pipe with synthetic account challenges."""

import json
import logging
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from unittest.mock import patch

import httpx
from audible import Authenticator
from audible_helper import main


REQUEST = {
    "command": "credentialSignIn",
    "marketplace": "uk",
    "username": "fixture@example.com",
    "password": " synthetic password ",
}
CAPTCHA = "https://www.amazon.co.uk/captcha/fixture.jpg"


class CredentialSignInTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(logging.disable, logging.root.manager.disable)

    def messages(self, request, *answers):
        lines = "\n".join(json.dumps(item) for item in (request, *answers))
        output = StringIO()
        with (
            patch("sys.stdin", StringIO(lines)),
            patch("audible_helper.WIRE", output),
            redirect_stdout(output),
            redirect_stderr(output),
        ):
            main()
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_challenges_and_session_use_the_same_pipe(self):
        signed_in = Authenticator.from_dict({"locale_code": "uk", "refresh_token": "Atnr|fixture"})

        def authenticate(**arguments):
            self.assertEqual(arguments["username"], REQUEST["username"])
            self.assertEqual(arguments["password"], REQUEST["password"])
            self.assertEqual(arguments["locale"].country_code, "uk")
            self.assertFalse(arguments["with_username"])
            self.assertEqual(arguments["captcha_callback"](CAPTCHA), "captcha")
            self.assertEqual(arguments["otp_callback"](), "123456")
            self.assertEqual(arguments["cvf_callback"](), "654321")
            self.assertEqual(arguments["approval_callback"](), "")
            return signed_in

        with patch.object(Authenticator, "from_login", side_effect=authenticate):
            messages = self.messages(
                REQUEST,
                {"answer": " CAPTCHA "},
                {"answer": "123456"},
                {"answer": "654321"},
                {"answer": ""},
            )

        self.assertEqual(messages[:-1], [
            {"signInChallenge": {"kind": "captcha", "imageURL": CAPTCHA}},
            {"signInChallenge": {"kind": "otp"}},
            {"signInChallenge": {"kind": "cvf"}},
            {"signInChallenge": {"kind": "approval"}},
        ])
        self.assertEqual(json.loads(messages[-1]["result"]["session"]), signed_in.to_dict())

    def test_closed_pipe_cancels_verification(self):
        def authenticate(**arguments):
            arguments["otp_callback"]()
            self.fail("Authentication continued after the app closed the pipe")

        with patch.object(Authenticator, "from_login", side_effect=authenticate):
            self.assertEqual(self.messages(REQUEST), [{"signInChallenge": {"kind": "otp"}}])

    def test_legacy_challenge_resolves_relative_image_url(self):
        def authenticate(**arguments):
            self.assertTrue(arguments["with_username"])
            arguments["captcha_callback"]("/captcha/fixture.jpg")

        with patch.object(Authenticator, "from_login", side_effect=authenticate):
            self.assertEqual(self.messages({**REQUEST, "legacyUsername": True}), [
                {"signInChallenge": {
                    "kind": "captcha", "imageURL": "https://www.audible.co.uk/captcha/fixture.jpg",
                }},
            ])

    def test_insecure_captcha_url_returns_only_safe_error(self):
        def authenticate(**arguments):
            arguments["captcha_callback"]("http://example.com/captcha.jpg")
            self.fail("Authentication continued after an insecure CAPTCHA URL")

        with patch.object(Authenticator, "from_login", side_effect=authenticate):
            self.assertEqual(self.messages(REQUEST), [{"error": "credentialSignInFailed"}])

    def test_upstream_errors_emit_only_safe_codes(self):
        secret = REQUEST["password"]
        for error, expected in (
            (ValueError(secret), "credentialSignInFailed"),
            (httpx.ConnectError(secret), "network"),
            (httpx.ReadTimeout(secret), "timeout"),
        ):
            def authenticate(**_):
                print(secret)
                print(secret, file=sys.stderr)
                raise error

            with self.subTest(expected=expected), patch.object(
                Authenticator, "from_login", side_effect=authenticate,
            ):
                self.assertEqual(self.messages(REQUEST), [{"error": expected}])

    def test_browser_request_still_works_without_a_trailing_newline(self):
        result = self.messages({"command": "beginSignIn", "marketplace": "uk"})[0]["result"]
        self.assertTrue(result["url"].startswith("https://www.amazon.co.uk/ap/signin?"))
        self.assertTrue(result["serial"])
        self.assertTrue(result["verifier"])

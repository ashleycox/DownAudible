"""Exercise the Android login and identity check with synthetic accounts."""

import base64
import gzip
import hashlib
import hmac
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import httpx
from audible import Authenticator
from audible.login import create_s256_code_challenge
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad

from android_sign_in import (
    ANDROID_DEVICE_TYPE,
    APP_NAME,
    APP_VERSION,
    refresh_android_access_token,
)
from audible_helper import AUTHORIZATION_CODE, begin_sign_in, complete_sign_in, execute
from download_transfer import OperationError

MARKET = {"deviceProfile": "android", "marketplace": "uk"}
ADDRESS = f"https://www.audible.co.uk/ap/maplanding?{AUTHORIZATION_CODE}=fixture-code"
REGISTER_URL = "https://api.amazon.co.uk/auth/register"


def registration_result(user_id="customer1", *, device=ANDROID_DEVICE_TYPE):
    return {
        "response": {
            "success": {
                "tokens": {
                    "bearer": {
                        "access_token": "Atna|fixture",
                        "refresh_token": "Atnr|fixture",
                        "expires_in": 3600,
                    },
                    "mac_dms": {
                        "adp_token": "{enc:fixture}{key:fixture}{iv:fixture}{name:fixture}{serial:Mg==}",
                        "device_private_key": "-----BEGIN PRIVATE KEY-----fixture-----END PRIVATE KEY-----\n",
                    },
                    "website_cookies": [],
                },
                "extensions": {
                    "device_info": {"device_type": device},
                    "customer_info": {"user_id": user_id},
                },
            }
        },
    }


class AndroidSignInTests(unittest.TestCase):
    def setUp(self):
        self.start = begin_sign_in(MARKET)
        self.request = {
            **MARKET,
            "redirect": ADDRESS,
            "serial": self.start["serial"],
            "verifier": self.start["verifier"],
            "registrationContext": self.start["registrationContext"],
        }

    def test_browser_url_binds_fresh_device_to_pkce_and_audible_callback(self):
        address = urlsplit(self.start["url"])
        self.assertEqual(
            (address.scheme, address.hostname, address.path),
            ("https", "www.amazon.co.uk", "/ap/signin"),
        )
        query = parse_qs(address.query)
        self.assertEqual(
            query["openid.return_to"], ["https://www.audible.co.uk/ap/maplanding"]
        )
        self.assertEqual(query["openid.assoc_handle"], ["amzn_audible_android_aui_uk"])
        self.assertEqual(query["pageId"], ["amzn_audible_android_aui_v2_dark_uk"])
        self.assertRegex(self.start["serial"], r"^[0-9a-f]{20}$")
        client_id = query["openid.oa2.client_id"][0].removeprefix("device:")
        self.assertEqual(
            bytes.fromhex(client_id).decode(),
            f"{self.start['serial']}#{ANDROID_DEVICE_TYPE}",
        )
        verifier = self.start["verifier"].encode("ascii")
        self.assertEqual(
            query["openid.oa2.code_challenge"],
            [create_s256_code_challenge(verifier).decode()],
        )
        self.assertNotIn(self.start["verifier"], address.query)
        self.assertNotIn(self.start["registrationContext"], address.query)
        self.assertNotEqual(begin_sign_in(MARKET)["serial"], self.start["serial"])

    def test_registration_context_is_bound_to_device_and_keeps_local_ip_private(self):
        payload = base64.b64decode(self.start["registrationContext"])
        seed = self.start["serial"].encode()
        mac = hashlib.pbkdf2_hmac("sha1", seed, b"HmacSHA256", 1000, 16)
        self.assertEqual(payload[:1], b"\0")
        self.assertEqual(payload[1:9], hmac.digest(mac, payload[9:], "sha256")[:8])
        key = hashlib.pbkdf2_hmac("sha1", seed, b"AES/CBC/PKCS7Padding", 1000, 16)
        context = AES.new(key, AES.MODE_CBC, payload[9:25]).decrypt(payload[25:])
        data = json.loads(gzip.decompress(unpad(context, AES.block_size)))
        self.assertEqual(data["FirstPartyDeviceId"], self.start["serial"])
        self.assertEqual(data["DeviceLanguage"], "en-GB")
        self.assertEqual(data["IpAddress"], "0.0.0.0")

    def test_android_registration_uses_first_party_and_keeps_existing_identity(self):
        def register(url, *, json, timeout, follow_redirects):
            self.assertEqual(url, REGISTER_URL)
            self.assertEqual(timeout, 45)
            self.assertFalse(follow_redirects)
            self.assertEqual(
                json["registration_data"]["device_type"], ANDROID_DEVICE_TYPE
            )
            self.assertEqual(
                json["registration_data"]["device_serial"], self.start["serial"]
            )
            self.assertEqual(json["auth_data"]["use_global_authentication"], "true")
            self.assertEqual(json["auth_data"]["code_verifier"], self.start["verifier"])
            self.assertEqual(
                json["user_context_map"]["frc"], self.start["registrationContext"]
            )
            return httpx.Response(
                200, json=registration_result(), request=httpx.Request("POST", url)
            )

        previous = json.dumps(
            {"locale_code": "uk", "customer_info": {"user_id": "customer1"}}
        )
        with patch("android_sign_in.httpx.post", side_effect=register) as send:
            result = complete_sign_in({**self.request, "previousSession": previous})
        self.assertEqual(send.call_count, 1)
        session = json.loads(result["session"])
        self.assertEqual(session["customer_info"]["user_id"], "customer1")
        self.assertEqual(session["device_info"]["device_type"], ANDROID_DEVICE_TYPE)
        self.assertEqual(session["locale_code"], "uk")

    def test_rejects_wrong_market_invalid_context_and_legacy_before_registration(self):
        scenarios = (
            (
                {"redirect": ADDRESS.replace("www.audible", "www.amazon")},
                "invalidRedirect",
            ),
            ({"redirect": ADDRESS.replace("co.uk", "com")}, "invalidRedirect"),
            (
                {"redirect": ADDRESS.replace("/ap/maplanding", "/elsewhere")},
                "invalidRedirect",
            ),
            ({"registrationContext": None}, "signInFailed"),
            ({"legacyUsername": True}, "signInFailed"),
            ({"previousSession": "not json"}, "accountVerification"),
            ({"previousSession": '{"locale_code":"us"}'}, "accountMismatch"),
        )
        with patch("android_sign_in.httpx.post") as send:
            for values, expected in scenarios:
                with (
                    self.subTest(expected=expected, fields=values.keys()),
                    self.assertRaises(OperationError) as caught,
                ):
                    complete_sign_in({**self.request, **values})
                self.assertEqual(caught.exception.code, expected)
        send.assert_not_called()

    def test_rejects_different_verified_customer_and_non_android_registration(self):
        previous = json.dumps(
            {"locale_code": "uk", "customer_info": {"user_id": "customer2"}}
        )
        for registration, expected in (
            (registration_result(), "accountMismatch"),
            (registration_result(device="unexpected"), "signInFailed"),
        ):
            response = httpx.Response(
                200, json=registration, request=httpx.Request("POST", REGISTER_URL)
            )
            with (
                self.subTest(expected=expected),
                patch("android_sign_in.httpx.post", return_value=response),
            ):
                with self.assertRaises(OperationError) as caught:
                    complete_sign_in({**self.request, "previousSession": previous})
                self.assertEqual(caught.exception.code, expected)

    def test_old_file_without_customer_info_can_be_verified_by_first_party_profile(
        self,
    ):
        previous = json.dumps(
            {
                "locale_code": "uk",
                "access_token": "Atna|original",
                "expires": 9_999_999_999,
            }
        )
        response = httpx.Response(
            200, json=registration_result(), request=httpx.Request("POST", REGISTER_URL)
        )
        with (
            patch.object(
                Authenticator,
                "user_profile",
                autospec=True,
                return_value={"user_id": "customer1"},
            ) as profile,
            patch("android_sign_in.httpx.post", return_value=response),
        ):
            result = complete_sign_in({**self.request, "previousSession": previous})
        self.assertEqual(profile.call_args.args[0].access_token, "Atna|original")
        self.assertEqual(
            json.loads(result["session"])["customer_info"]["user_id"], "customer1"
        )


class AndroidAccessTokenTests(unittest.IsolatedAsyncioTestCase):
    async def test_refresh_keeps_android_profile_and_sends_only_to_own_market(self):
        auth = SimpleNamespace(
            refresh_token="Atnr|fixture",
            locale=SimpleNamespace(domain="co.uk"),
            with_username=False,
            access_token=None,
            expires=None,
        )

        def respond(request):
            self.assertEqual(str(request.url), "https://api.amazon.co.uk/auth/token")
            self.assertEqual(
                request.headers["x-amzn-identity-auth-domain"], "api.amazon.co.uk"
            )
            self.assertEqual(
                parse_qs(request.content.decode()),
                {
                    "app_name": [APP_NAME],
                    "app_version": [APP_VERSION],
                    "source_token": ["Atnr|fixture"],
                    "requested_token_type": ["access_token"],
                    "source_token_type": ["refresh_token"],
                },
            )
            return httpx.Response(
                200, json={"access_token": "Atna|updated", "expires_in": 3600}
            )

        real_client = httpx.AsyncClient
        mock_transport = httpx.MockTransport(respond)
        with patch(
            "android_sign_in.httpx.AsyncClient",
            side_effect=lambda **args: real_client(transport=mock_transport, **args),
        ):
            await refresh_android_access_token(auth, 10)
        self.assertEqual(auth.access_token, "Atna|updated")

    async def test_helper_rejects_android_password_mode(self):
        with self.assertRaises(OperationError) as caught:
            await execute({**MARKET, "command": "credentialSignIn"})
        self.assertEqual(caught.exception.code, "credentialSignInFailed")

"""Check OpenAudible import without using an existing account."""

import json
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx
from audible_helper import execute
from download_transfer import OperationError


def registration(country, customer, expiry):
    return {
        "region": country,
        "expires": expiry,
        "details": {"response": {"success": {
            "tokens": {
                "mac_dms": {
                    "adp_token": "{enc:synthetic}{key:synthetic}{iv:synthetic}{name:synthetic}{serial:Mg==}",
                    "device_private_key": "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----\n",
                },
                "bearer": {"access_token": "Atna|synthetic", "refresh_token": "Atnr|synthetic"},
                "website_cookies": [{"Name": "session-id", "Value": '"synthetic-cookie"'}],
            },
            "extensions": {
                "device_info": {"device_type": "A2CZJZGLK2JJVM", "device_serial_number": "FIXTURE1234"},
                "customer_info": {"user_id": customer},
            },
        }}},
    }


class OpenAudibleImportTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.path = Path(folder.name) / "credentials.json"
        self.profiles = {
            "active_device": "Personal UK",
            "Personal US": registration("US", "fixture-us", 4102444800000),
            "Personal UK": registration("GB", "fixture-uk", 4102444800),
            "Corrupt profile": {"region": "US"},
        }
        self.write(self.profiles)

    def write(self, contents):
        self.path.write_text(json.dumps(contents), encoding="utf-8")

    async def inspect(self):
        return await execute({"command": "inspectOpenAudible", "file": str(self.path)})

    async def import_profile(self, checkpoint):
        return await execute({"command": "importOpenAudible", "file": str(self.path), "checkpoint": checkpoint})

    async def test_offline_inspection_exposes_only_labels_and_selection_keys(self):
        profiles = await self.inspect()
        self.assertEqual([profile["name"] for profile in profiles], ["Personal UK", "Personal US"])
        self.assertEqual([profile["marketplace"] for profile in profiles], ["uk", "us"])
        self.assertTrue(profiles[0]["isDefault"])
        self.assertNotIn("synthetic", json.dumps(profiles))
        self.assertTrue(all(len(profile["checkpoint"]) == 64 for profile in profiles))

    async def test_selected_registration_is_verified_without_writing_credentials(self):
        profiles = await self.inspect()
        original = self.path.read_bytes()
        profile_request = httpx.Request("GET", "https://api.amazon.com/user/profile")
        profile_response = httpx.Response(200, json={"user_id": "fixture-us"}, request=profile_request)
        with (
            patch("open_audible_import.httpx.AsyncClient") as profile_client,
            patch("open_audible_import.audible.AsyncClient") as audible_client,
        ):
            get_profile = AsyncMock(return_value=profile_response)
            profile_client.return_value.__aenter__.return_value.get = get_profile
            get_library = AsyncMock(return_value={"items": []})
            audible_client.return_value.__aenter__.return_value.get = get_library
            result = await self.import_profile(profiles[1]["checkpoint"])
            get_profile.assert_awaited_once()
            self.assertEqual(get_profile.call_args.args[0], "https://api.amazon.com/user/profile")
            get_library.assert_awaited_once_with("library", page=1, num_results=1)
        self.assertEqual(result["marketplace"], "us")
        session = json.loads(result["session"])
        self.assertEqual(session["expires"], 4102444800)
        self.assertEqual(session["customer_info"]["user_id"], "fixture-us")
        self.assertEqual(session["website_cookies"], {"session-id": "synthetic-cookie"})
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    async def test_reject_changed_selection_before_requesting_audible(self):
        profiles = await self.inspect()
        changed = deepcopy(self.profiles)
        changed["Personal UK"]["expires"] -= 1000
        self.write(changed)
        with patch("open_audible_import._verify_registration", new_callable=AsyncMock) as verify:
            with self.assertRaisesRegex(OperationError, "openAudibleChanged"):
                await self.import_profile(profiles[0]["checkpoint"])
            verify.assert_not_awaited()

    async def test_reject_sign_in_for_a_different_customer(self):
        profiles = await self.inspect()
        request = httpx.Request("GET", "https://api.amazon.co.uk/user/profile")
        response = httpx.Response(200, json={"user_id": "different-fixture"}, request=request)
        with (
            patch("open_audible_import.httpx.AsyncClient") as profile_client,
            patch("open_audible_import.audible.AsyncClient") as audible_client,
        ):
            profile_client.return_value.__aenter__.return_value.get = AsyncMock(return_value=response)
            with self.assertRaisesRegex(OperationError, "accountMismatch"):
                await self.import_profile(profiles[0]["checkpoint"])
            audible_client.assert_not_called()

    async def test_refresh_expired_profile_with_optional_fields_omitted(self):
        expired = registration("US", "fixture-us", "0")
        tokens = expired["details"]["response"]["success"]["tokens"]
        tokens.pop("website_cookies")
        tokens["bearer"].pop("access_token")
        self.write({"Personal US": expired})
        profile, = await self.inspect()

        async def refresh(auth, force=False):
            self.assertTrue(force)
            auth.access_token = "Atna|renewed-fixture"
            auth.expires = 4102444800

        request = httpx.Request("GET", "https://api.amazon.com/user/profile")
        response = httpx.Response(200, json={"user_id": "fixture-us"}, request=request)
        with (
            patch("open_audible_import.httpx.AsyncClient") as profile_client,
            patch("open_audible_import.audible.AsyncClient") as audible_client,
            patch("open_audible_import.audible.Authenticator.async_refresh_access_token", refresh),
        ):
            remote = AsyncMock(return_value=response)
            profile_client.return_value.__aenter__.return_value.get = remote
            audible_client.return_value.__aenter__.return_value.get = AsyncMock(return_value={"items": []})
            result = await self.import_profile(profile["checkpoint"])
        self.assertEqual(remote.call_args.kwargs["headers"]["x-amz-access-token"], "Atna|renewed-fixture")
        self.assertEqual(json.loads(result["session"])["access_token"], "Atna|renewed-fixture")

    async def test_reject_malformed_and_oversized_files(self):
        for invalid in (b"[]", b"{}", b'{"record": {}, "record": {}}', b" " * (2**20 + 1)):
            with self.subTest(length=len(invalid)):
                self.path.write_bytes(invalid)
                with self.assertRaisesRegex(OperationError, "openAudibleFile"):
                    await self.inspect()


if __name__ == "__main__":
    unittest.main()

import errno
import json
import tempfile
import unittest
import warnings
from datetime import UTC, datetime
from io import BytesIO
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit

import httpx
from audible import AsyncClient
from audible.aescipher import AESCipher
from audible.exceptions import NotFoundError
from audible_helper import (
    catalog_search,
    chapters_from,
    cli_profiles,
    edit_wishlist,
    execute,
    failure_code,
    list_books,
)
from download_transfer import OperationError

ACCOUNT = {
    "locale_code": "uk",
    "adp_token": "{enc:fixture}{key:fixture}{iv:fixture}{name:fixture}{serial:Mg==}",
    "device_private_key": "-----BEGIN RSA PRIVATE KEY-----\nfixture\n-----END RSA PRIVATE KEY-----\n",
    "activation_bytes": "11223344",
}
ASIN = "B000000001"


class AccountToolsTests(unittest.IsolatedAsyncioTestCase):
    async def test_download_distinguishes_aaxc_license_and_service_failures(self):
        def denied(*reasons):
            return {"content_license": {
                "status_code": "Denied", "message": "Private fixture text",
                "license_denial_reasons": [
                    {"validationType": kind, "rejectionReason": reason}
                    for kind, reason in reasons
                ],
            }}

        cases = (
            (200, denied(("Client", "RequesterEligibility")), "licenseDenied"),
            (200, denied(("Ownership", "RequesterEligibility")), "licenseEntitlement"),
            (200, denied(("Ownership", "RequesterEligibility"), ("AYCL", "CustomerThrottled")), "licenseThrottled"),
            (200, {"content_license": {"status_code": "Granted"}}, "aaxcUnavailable"),
            (404, {"error_code": "000307"}, "aaxcUnavailable"),
            (200, {}, "licenseResponse"),
            (401, {}, "authorization"),
            (403, {}, "requestRejected"),
            (404, {}, "notFound"),
            (429, {}, "rateLimited"),
            (503, {}, "serverUnavailable"),
        )

        async def sign(_auth, request):
            yield request

        for status, payload, expected in cases:
            def respond(request):
                if request.url.path.endswith(f"/library/{ASIN}"):
                    return httpx.Response(200, json={"item": {
                        "asin": ASIN, "title": "Download fixture",
                        "customer_rights": {"is_consumable_offline": True},
                    }})
                self.assertTrue(request.url.path.endswith(f"/{ASIN}/licenserequest"))
                return httpx.Response(status, json=payload)

            def client(*args, **kwargs):
                return AsyncClient(*args, transport=httpx.MockTransport(respond), **kwargs)

            with (
                self.subTest(expected=expected),
                tempfile.TemporaryDirectory() as directory,
                patch("audible_helper.audible.AsyncClient", new=client),
                patch("audible.Authenticator.async_auth_flow", new=sign),
            ):
                with self.assertRaises(Exception) as caught:
                    await execute({
                        "command": "download", "session": json.dumps(ACCOUNT),
                        "asin": ASIN, "directory": directory, "options": {"format": "aaxcOnly"},
                    })
                self.assertEqual(failure_code(caught.exception, "download"), expected)

    def test_download_errors_use_safe_codes_for_disk_and_timeout(self):
        path = "/private/fixture/secret"
        self.assertEqual(failure_code(OSError(errno.ENOSPC, "", path), "download"), "diskFull")
        self.assertEqual(failure_code(OSError(errno.EACCES, "", path), "download"), "stagingFileAccess")
        self.assertEqual(failure_code(httpx.ReadTimeout(path), "download"), "timeout")

    async def test_activation_keeps_valid_cached_bytes(self):
        with patch("audible_helper.build_opener") as build_opener:
            result = await execute(
                {"command": "activation", "session": json.dumps(ACCOUNT)}
            )
        build_opener.assert_not_called()
        self.assertEqual(result["activationBytes"], ACCOUNT["activation_bytes"])

    async def test_activation_refresh_sends_signed_request_and_updates_session(self):
        signed_urls = []

        def sign(auth, request):
            signed_urls.append(str(request.url))
            request.headers["x-adp-token"] = auth.adp_token
            request.headers["x-adp-signature"] = "fixture-signature"
            yield request

        activation = "aabbccdd"
        key = int(activation, 16).to_bytes(4, "little")
        blob = b"group_id" + key + bytes(0x238 - len(key))
        with (
            patch(
                "audible.Authenticator.sync_auth_flow", side_effect=sign, autospec=True
            ),
            patch("audible_helper.build_opener") as build_opener,
        ):
            opener = build_opener.return_value
            opener.open.return_value = BytesIO(blob)
            result = await execute(
                {
                    "command": "activation",
                    "session": json.dumps(ACCOUNT),
                    "refreshActivation": True,
                    "options": {"timeout": 12},
                }
            )
        opener.open.assert_called_once()
        request = opener.open.call_args.args[0]
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 12)
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(signed_urls, [request.full_url])
        self.assertEqual(urlsplit(request.full_url).hostname, "www.audible.com")
        self.assertEqual(urlsplit(request.full_url).path, "/license/token")
        headers = {key.lower(): value for key, value in request.header_items()}
        self.assertEqual(headers["x-adp-token"], ACCOUNT["adp_token"])
        self.assertEqual(headers["x-adp-signature"], "fixture-signature")
        self.assertEqual(result["activationBytes"], activation)
        self.assertEqual(json.loads(result["session"])["activation_bytes"], activation)

    async def test_activation_reports_forbidden_responses_and_network_errors(self):
        def sign(_auth, request):
            yield request

        request = {
            "command": "activation",
            "session": json.dumps({**ACCOUNT, "activation_bytes": None}),
        }
        for error, expected in (
            (
                HTTPError(
                    "https://www.audible.com/license/token",
                    403,
                    "Forbidden",
                    None,
                    BytesIO(b"<html>Request blocked</html>"),
                ),
                "activation",
            ),
            (URLError(TimeoutError()), "network"),
        ):
            with (
                self.subTest(expected=expected),
                patch(
                    "audible.Authenticator.sync_auth_flow",
                    side_effect=sign,
                    autospec=True,
                ),
                patch("audible_helper.build_opener") as build_opener,
            ):
                build_opener.return_value.open.side_effect = error
                with self.assertRaises(OperationError) as caught:
                    await execute(request)
                self.assertEqual(caught.exception.code, expected)

    def test_cli_profiles_skip_invalid_auth_files(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            config = folder / "config.toml"
            config.write_text(
                '[APP]\nprimary_profile = "saved"\n'
                '[profile.broken]\nauth_file = "broken.json"\n'
                '[profile.truncated]\nauth_file = "truncated"\n'
                '[profile.saved]\nauth_file = "account.json"\n'
                '[profile.protected]\nauth_file = "account.bin"\n'
            )
            (folder / "broken.json").write_text("null")
            (folder / "truncated").write_bytes(b"\x80\x81")
            (folder / "account.json").write_text(json.dumps(ACCOUNT))
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                (folder / "account.bin").write_bytes(
                    AESCipher("fixture-password").to_bytes(json.dumps(ACCOUNT))
                )
            profiles = cli_profiles({"file": str(config)})
        self.assertEqual([profile["name"] for profile in profiles], ["saved", "protected"])
        self.assertTrue(profiles[0]["isDefault"])
        self.assertFalse(profiles[0]["requiresPassword"])
        self.assertTrue(profiles[1]["requiresPassword"])

    def test_chapters_skip_incomplete_metadata(self):
        def metadata(chapters):
            return {"content_metadata": {"chapter_info": {"chapters": chapters}}}

        self.assertEqual(chapters_from(metadata(None)), [])
        chapters = [
            None,
            {"start_offset_ms": 0, "length_ms": 1000, "title": 1},
            {"start_offset_ms": 0, "length_ms": True, "title": "Invalid"},
            {"start_offset_ms": 0, "length_ms": 2**63, "title": "Out of range"},
            {"start_offset_ms": 1000, "length_ms": 1000, "title": "Chapter"},
        ]
        self.assertEqual(
            chapters_from(metadata(chapters)),
            [{"startMilliseconds": 1000, "durationMilliseconds": 1000, "title": "Chapter"}],
        )

    async def test_library_excludes_wishlist_only_items_and_reports_availability(self):
        calls = []

        class Service:
            async def get(self, path, **options):
                calls.append(path)
                if path == "wishlist":
                    return {"products": [{"asin": "B000000005", "title": "Wish List only"}]}
                items = [
                    {"asin": ASIN, "title": "Owned and wishlisted", "in_wishlist": True},
                    {
                        "asin": "B000000002",
                        "title": "Offline restricted",
                        "customer_rights": {"is_consumable_offline": False},
                    },
                    {
                        "asin": "B000000003",
                        "title": "Upcoming",
                        "publication_datetime": "2999-01-01T00:00:00Z",
                    },
                    {
                        "asin": "B000000004",
                        "title": "Podcast series",
                        "content_delivery_type": "PodcastParent",
                        "content_type": "Podcast",
                        "has_children": True,
                    },
                ]
                return httpx.Response(200, json={"items": items}, headers={"total-count": "4"})

        books = await list_books(Service(), {"podcasts": "showSeries"})
        self.assertEqual(calls, ["library"])
        self.assertEqual(
            [
                (book["asin"], book["isDownloadable"], book["downloadUnavailableReason"])
                for book in books
            ],
            [
                (ASIN, True, None),
                ("B000000002", False, "offlineRestricted"),
                ("B000000003", False, "unpublished"),
                ("B000000004", False, "podcastSeries"),
            ],
        )

    async def test_library_keeps_books_with_incomplete_optional_metadata(self):
        class Service:
            async def get(self, path, **options):
                item = {
                    "asin": ASIN,
                    "title": "Incomplete optional metadata",
                    "runtime_length_min": "unknown",
                    "purchase_date": "",
                    "publication_datetime": "unknown",
                    "category_ladders": [{"ladder": None}],
                }
                return httpx.Response(
                    200, json={"items": [item]}, headers={"total-count": "1"}
                )

        books = await list_books(Service(), {"purchaseStart": 0})
        self.assertEqual(len(books), 1)
        self.assertIsNone(books[0]["durationSeconds"])
        self.assertTrue(books[0]["isDownloadable"])
        self.assertEqual(books[0]["genres"], [])

    async def test_purchase_range_applies_to_catalogue_podcast_episodes(self):
        episodes = [
            {
                "asin": "B000000002",
                "title": "Within range",
                "purchase_date": "2026-02-01T00:00:00Z",
            },
            {
                "asin": "B000000003",
                "title": "After range",
                "purchase_date": "2026-03-01T00:00:00Z",
            },
        ]
        calls = []

        class Service:
            async def get(self, path, **options):
                calls.append((path, options))
                if path == "catalog/products":
                    return {"products": episodes}
                if options.get("parent_asin"):
                    items = episodes[:1]
                else:
                    items = [
                        {
                            "asin": ASIN,
                            "title": "Podcast",
                            "content_type": "Podcast",
                            "content_delivery_type": "PodcastParent",
                            "has_children": True,
                            "episode_count": 2,
                        }
                    ]
                return httpx.Response(
                    200, json={"items": items}, headers={"total-count": "1"}
                )

        books = await list_books(
            Service(),
            {
                "podcasts": "resolveEpisodes",
                "purchaseEnd": datetime(2026, 2, 15, tzinfo=UTC).timestamp(),
            },
        )
        self.assertEqual([book["asin"] for book in books], ["B000000002"])
        self.assertEqual(calls[-1][0], "catalog/products")
        self.assertNotIn("end_date", calls[-1][1])

    async def test_export_encrypts_cli_account(self):
        request = {"command": "exportAuthFile", "session": json.dumps(ACCOUNT)}
        with self.assertRaisesRegex(OperationError, "exportPassword"):
            await execute(request)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            exported = await execute({**request, "password": "fixture-password"})
            decoded = json.loads(
                AESCipher("fixture-password").from_dict(json.loads(exported))
            )
        self.assertNotIn("device_private_key", exported)
        self.assertNotIn("fixture-password", exported)
        self.assertEqual(decoded["adp_token"], ACCOUNT["adp_token"])
        self.assertEqual(decoded["locale_code"], ACCOUNT["locale_code"])

    async def test_catalog_accepts_exact_asin_or_title(self):
        matches = [{"asin": ASIN, "title": "A catalogue fixture"}]
        queries = []

        class Catalogue:
            async def get(self, path, **options):
                queries.append((path, options))
                if path == "catalog/products/FOUNDATION":
                    return {}
                return (
                    {"products": matches}
                    if path == "catalog/products"
                    else {"product": matches[0]}
                )

        client = Catalogue()
        exact = await catalog_search(client, ASIN.lower())
        by_title = await catalog_search(client, "catalogue")
        by_ten_character_title = await catalog_search(client, "Foundation")
        self.assertEqual(exact, by_title)
        self.assertEqual(exact, by_ten_character_title)
        self.assertEqual(exact[0]["title"], matches[0]["title"])
        self.assertEqual(queries[0][0], f"catalog/products/{ASIN}")
        self.assertEqual(queries[1][1]["title"], "catalogue")

    async def test_wishlist_mutations_only_use_valid_requested_asins(self):
        calls = []

        class Service:
            async def post(self, path, *, body):
                calls.append((path, body))

            async def delete(self, path):
                calls.append((path, None))
                response = httpx.Response(
                    404, request=httpx.Request("DELETE", "https://api.example.test")
                )
                raise NotFoundError(response, {})

        client = Service()
        invalid = "../not-an-asin"
        rejected = await edit_wishlist(client, "wishlistAdd", [ASIN, ASIN, invalid])
        self.assertEqual(rejected, {invalid: "invalidTitle"})
        absent = await edit_wishlist(client, "wishlistRemove", [ASIN])
        self.assertEqual(absent, {})
        self.assertEqual(
            calls, [("wishlist", {"asin": ASIN}), (f"wishlist/{ASIN}", None)]
        )

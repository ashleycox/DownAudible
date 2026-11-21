import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx
from audible.exceptions import RatelimitError
from audible_helper import execute, failure_code
from download_transfer import FormatUnavailable
from httpx import AsyncClient

ACCOUNT = {
    "locale_code": "uk",
    "adp_token": "{enc:fixture}{key:fixture}{iv:fixture}{name:fixture}{serial:Mg==}",
    "device_private_key": "-----BEGIN RSA PRIVATE KEY-----\nfixture\n-----END RSA PRIVATE KEY-----\n",
    "activation_bytes": "11223344",
}
BOOK = "B000000001"
PARTS = ("B000000003", "B000000002")
CDN = "https://cdn.example.test"
FIXTURE_VOUCHER = {"key": "11" * 16, "iv": "22" * 16}


def item(asin, delivery_type):
    return {
        "asin": asin,
        "title": "Download fixture",
        "content_delivery_type": delivery_type,
        "has_children": delivery_type == "MultiPartBook",
        "customer_rights": {"is_consumable_offline": True},
        "available_codecs": [{"name": "aax_44_128", "enhanced_codec": "AAX_44_128"}],
    }


def license_for(asin):
    return httpx.Response(200, json={
        "content_license": {
            "status_code": "Granted",
            "license_response": "fixture voucher",
            "content_metadata": {
                "content_reference": {"content_format": "AAXC"},
                "content_url": {"offline_url": f"{CDN}/{asin}.aaxc"},
            },
        },
    })


def audio(asset):
    return b"\x00\x00\x00\x20ftypaax " + asset.encode("ascii")


class DownloadBookTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.requests = []

    async def download(
        self, mode, *, aax=(), licenses=None, parts=False, include_book_rights=True, book_aaxc_status=200
    ):
        licenses = licenses or {}

        def respond(request):
            path = request.url.path
            if path == f"/1.0/library/{BOOK}":
                self.requests.append(("book", BOOK))
                book = item(BOOK, "MultiPartBook")
                if not include_book_rights:
                    del book["customer_rights"]
                return httpx.Response(200, json={"item": book})
            if path == "/1.0/library" and parts:
                self.assertEqual(request.url.params["parent_asin"], BOOK)
                self.requests.append(("parts", BOOK))
                return httpx.Response(200, headers={"total-count": "3"}, json={
                    "items": [
                        item(PARTS[0], "AudioPart"),
                        item("B000000004", "PodcastEpisode"),
                        item(PARTS[1], "AudioPart"),
                    ],
                })
            if path.endswith("/FSDownloadContent") and aax:
                asin = request.url.params["key"]
                self.assertIn(asin, aax)
                return httpx.Response(302, headers={"location": f"{CDN}/{asin}.aax"})
            if path == "/library/download" and BOOK in aax:
                self.assertEqual(request.url.params["asin"], BOOK)
                self.requests.append(("webAAX", BOOK))
                return httpx.Response(404)
            if path.endswith("/licenserequest"):
                asin = path.split("/")[-2]
                self.assertIn(asin, licenses)
                self.requests.append(("license", asin))
                return licenses[asin]
            if request.url.host == "cdn.example.test":
                filename = request.url.path.lstrip("/")
                asin, extension = filename.split(".")
                self.requests.append((extension, asin))
                if extension == "aax" and asin == BOOK:
                    return httpx.Response(200, text="Please download individual parts.")
                if extension == "aaxc" and asin == BOOK and book_aaxc_status != 200:
                    return httpx.Response(book_aaxc_status)
                return httpx.Response(200, headers={"content-type": "audio/aax"}, content=audio(filename))
            self.fail(f"Unexpected request: {request.method} {request.url}")

        def client(*args, **kwargs):
            return AsyncClient(*args, transport=httpx.MockTransport(respond), **kwargs)

        async def sign(_auth, request):
            yield request

        with (
            patch("httpx.AsyncClient", new=client),
            patch("audible.Authenticator.async_auth_flow", new=sign),
            patch("audible_cli.models.decrypt_voucher_from_licenserequest", return_value=FIXTURE_VOUCHER),
            patch("audible_helper.emit"),
        ):
            return await execute({
                "command": "download",
                "session": json.dumps(ACCOUNT),
                "asin": BOOK,
                "directory": str(self.directory),
                "options": {"format": mode},
            })

    def assert_files(self, result, asins, extension):
        self.assertEqual([part["asin"] for part in result["parts"]], list(asins))
        self.assertEqual([part["file"] for part in result["parts"]], [
            f"{asin}.{extension}" for asin in asins
        ])
        for part in result["parts"]:
            self.assertEqual((self.directory / part["file"]).read_bytes(), audio(part["file"]))
            if extension == "aaxc":
                self.assertEqual(part["credentials"], {
                    "contentKey": FIXTURE_VOUCHER["key"], "contentIV": FIXTURE_VOUCHER["iv"],
                })

    async def test_multipart_book_downloads_as_one_file_when_available(self):
        result = await self.download("aaxcOnly", licenses={BOOK: license_for(BOOK)})
        self.assert_files(result, (BOOK,), "aaxc")
        self.assertEqual(self.requests, [("book", BOOK), ("license", BOOK), ("aaxc", BOOK)])

    async def test_prefer_aax_tries_whole_aaxc_when_aax_requires_parts(self):
        result = await self.download("preferAAX", aax=(BOOK,), licenses={BOOK: license_for(BOOK)})
        self.assert_files(result, (BOOK,), "aaxc")
        self.assertEqual(self.requests, [
            ("book", BOOK), ("aax", BOOK), ("webAAX", BOOK), ("license", BOOK), ("aaxc", BOOK)
        ])

    async def test_aax_only_falls_back_to_aax_parts(self):
        result = await self.download("aaxOnly", aax=(BOOK, *PARTS), parts=True)
        self.assert_files(result, PARTS, "aax")
        self.assertEqual(self.requests, [
            ("book", BOOK), ("aax", BOOK), ("webAAX", BOOK), ("parts", BOOK),
            ("aax", PARTS[0]), ("aax", PARTS[1]),
        ])

    async def test_aaxc_with_no_whole_book_link_downloads_parts_in_library_order(self):
        licenses = {asin: license_for(asin) for asin in PARTS}
        licenses[BOOK] = httpx.Response(200, json={"content_license": {"status_code": "Granted"}})
        result = await self.download("aaxcOnly", licenses=licenses, parts=True)
        self.assert_files(result, PARTS, "aaxc")
        self.assertEqual(self.requests, [
            ("book", BOOK), ("license", BOOK), ("parts", BOOK),
            ("license", PARTS[0]), ("aaxc", PARTS[0]),
            ("license", PARTS[1]), ("aaxc", PARTS[1]),
        ])

    async def test_multipart_book_without_parent_rights_metadata_downloads_parts(self):
        result = await self.download(
            "aaxcOnly", licenses={asin: license_for(asin) for asin in PARTS},
            parts=True, include_book_rights=False,
        )
        self.assert_files(result, PARTS, "aaxc")
        self.assertEqual(self.requests[:2], [("book", BOOK), ("parts", BOOK)])

    async def test_missing_whole_aaxc_download_uses_parts(self):
        result = await self.download(
            "aaxcOnly", licenses={asin: license_for(asin) for asin in (BOOK, *PARTS)},
            parts=True, book_aaxc_status=404,
        )
        self.assert_files(result, PARTS, "aaxc")
        self.assertEqual(self.requests[:4], [
            ("book", BOOK), ("license", BOOK), ("aaxc", BOOK), ("parts", BOOK)
        ])

    async def test_forbidden_whole_aaxc_download_surfaces_without_attempting_parts(self):
        with self.assertRaises(FormatUnavailable) as caught:
            await self.download("aaxcOnly", licenses={BOOK: license_for(BOOK)}, book_aaxc_status=403)
        self.assertEqual(failure_code(caught.exception, "download"), "sourceRejected")
        self.assertEqual(self.requests, [("book", BOOK), ("license", BOOK), ("aaxc", BOOK)])

    async def test_rate_limit_surfaces_without_attempting_parts(self):
        with self.assertRaises(RatelimitError) as caught:
            await self.download("aaxcOnly", licenses={BOOK: httpx.Response(429, json={})})
        self.assertEqual(failure_code(caught.exception, "download"), "rateLimited")
        self.assertEqual(self.requests, [("book", BOOK), ("license", BOOK)])

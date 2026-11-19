import json
import unittest
import warnings

import httpx
from audible.aescipher import AESCipher
from audible.exceptions import NotFoundError
from audible_helper import catalog_search, edit_wishlist, execute, list_books
from download_transfer import OperationError

ACCOUNT = {
    "locale_code": "uk",
    "adp_token": "{enc:fixture}{key:fixture}{iv:fixture}{name:fixture}{serial:Mg==}",
    "device_private_key": "-----BEGIN RSA PRIVATE KEY-----\nfixture\n-----END RSA PRIVATE KEY-----\n",
    "activation_bytes": "11223344",
}
ASIN = "B000000001"


class AccountToolsTests(unittest.IsolatedAsyncioTestCase):
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
        self.assertEqual(rejected, [invalid])
        absent = await edit_wishlist(client, "wishlistRemove", [ASIN])
        self.assertEqual(absent, [])
        self.assertEqual(
            calls, [("wishlist", {"asin": ASIN}), (f"wishlist/{ASIN}", None)]
        )

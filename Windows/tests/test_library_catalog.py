import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path

from downaudible_windows.library_catalog import (
    Catalogue,
    access_label,
    book_identity,
    parse_tags,
    progress_label,
)


class CatalogueTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.catalogue = Catalogue(self.path)
        self.now = datetime(2025, 5, 1, tzinfo=UTC)

    def test_offline_catalogues_keep_accounts_with_the_same_asin_separate(self):
        for account, title in (("profile-a", "First copy"), ("profile-b", "Second copy")):
            self.catalogue.record(account, [{"asin": "DEMO000001", "title": title}], {}, now=self.now)
        reopened = Catalogue(self.path)
        self.assertEqual(reopened.get("profile-a")["books"][0]["title"], "First copy")
        self.assertEqual(reopened.get("profile-b")["books"][0]["title"], "Second copy")
        self.assertNotEqual(book_identity({"asin": "DEMO000001", "_account_id": "profile-a"}),
                            book_identity({"asin": "DEMO000001", "_account_id": "profile-b"}))
        reopened.remove("profile-a")
        self.assertIsNone(Catalogue(self.path).get("profile-a"))
        self.assertIsNotNone(Catalogue(self.path).get("profile-b"))

    def test_only_equivalent_refreshes_produce_differences(self):
        first, second = [{"asin": "First"}], [{"asin": "Second"}]
        self.catalogue.record("account", first, {"podcasts": "ignore"}, now=self.now)
        entry = self.catalogue.record("account", second, {"podcasts": "ignore"}, now=self.now)
        self.assertEqual([(row["asin"], row["change"]) for row in entry["changes"]],
                         [("Second", "Added"), ("First", "No longer listed")])
        entry = self.catalogue.record("account", first, {"podcasts": "showSeries"}, now=self.now)
        self.assertEqual(entry["changes"], [])

    def test_access_progress_and_tag_values_keep_unknowns_distinct(self):
        self.assertEqual(access_label({"isAudiblePlus": True, "isIndefinite": False}), "Audible Plus")
        self.assertEqual(access_label({"isIndefinite": True}), "Indefinite Access")
        self.assertEqual(access_label({"isAudiblePlus": False, "isIndefinite": False}), "Other Titles")
        self.assertEqual(access_label({"isAudiblePlus": False}), "Unknown")
        self.assertEqual(progress_label({"isFinished": True}), "Finished")
        self.assertEqual(progress_label({"percentComplete": 2.1}), "In Progress")
        self.assertEqual(progress_label({"percentComplete": 0}), "Not Started")
        self.assertEqual(progress_label({"percentComplete": True}), "Unknown")
        self.assertEqual(parse_tags("  Gothic, COMEDY, gothic,  Space   Opera,,"), ["Gothic", "COMEDY", "Space Opera"])

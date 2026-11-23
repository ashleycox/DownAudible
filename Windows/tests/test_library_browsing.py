import csv
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import Mock
from xml.etree import ElementTree
from zipfile import ZipFile

try:
    from downaudible_windows.audible_tools import filter_wishlist
    from downaudible_windows.library import (
        LibraryPanel,
        browse_books,
        export_data,
        filter_candidates,
        filter_value,
        matching_suggestions,
    )
except ModuleNotFoundError as error:
    if error.name != "wx":
        raise
    LibraryPanel = None


@unittest.skipIf(LibraryPanel is None, "Requires wxPython")
class LibraryBrowsingTests(unittest.TestCase):
    def test_default_sort_uses_natural_titles_and_keeps_missing_values_last(self):
        books = [
            dict(asin="A", title="Book 10", authors=["Alex"]),
            dict(asin="B", title="Bóok 2", authors=["Alex", "Zed"]),
            dict(asin="C", title="Book 1", authors=[]),
        ]
        for reverse, expected in ((False, ["B", "A", "C"]), (True, ["B", "A", "C"])):
            with self.subTest(reverse=reverse):
                rows = browse_books(books, "", {}, "authors", reverse, lambda book: "Downloaded")
                self.assertEqual([book["asin"] for book in rows], expected)

    def test_release_year_uses_an_exact_number_with_other_filters_and_search(self):
        books = [
            dict(asin="A", title="Chapter 10", authors=["Álex"], releaseDate="2024-09-15"),
            dict(asin="B", title="Chapter 2", authors=["Alex"], releaseDate="2023-09-15"),
        ]
        self.assertEqual(filter_value("releaseYear", " +02024 "), "2024")
        rows = browse_books(books, "chapter", {"authors": "alex", "releaseYear": "02024", "status": "Downloaded"},
                            "title", False, lambda book: "Downloaded")
        self.assertEqual(rows, books[:1])
        for invalid in ("0", "10000", "-2024", "2_024", "2024-09-15"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                filter_value("releaseYear", invalid)

    def test_exports_preserve_order_and_keep_library_only_delimited_columns_separate(self):
        books = [dict(asin="B", title="Quoted,\n name", subtitle=None, hasPDF=False), dict(asin="A", title="Second")]
        data = json.loads(export_data(books, ".json"))
        self.assertEqual([book["asin"] for book in data], ["B", "A"])
        self.assertNotIn("subtitle", data[0])
        self.assertIs(data[0]["hasPDF"], False)
        library = list(csv.DictReader(io.StringIO(export_data(books, ".csv").decode())))
        wishlist = list(csv.DictReader(io.StringIO(export_data(books, ".tsv", wishlist=True).decode()), delimiter="\t"))
        self.assertEqual(library[0]["Title"], books[0]["title"])
        self.assertIn("Purchased", library[0])
        self.assertNotIn("Purchased", wishlist[0])
        for wanted in (False, True):
            with self.subTest(wishlist=wanted), ZipFile(io.BytesIO(export_data(books, ".xlsx", wishlist=wanted))) as xlsx:
                data = ElementTree.fromstring(xlsx.read("xl/worksheets/sheet1.xml"))
                self.assertEqual(data.find(".//{*}c[@r='A2']/{*}is/{*}t").text, "B")
                self.assertEqual(data.find(".//{*}c[@r='A3']/{*}is/{*}t").text, "A")
                purchase = data.find(".//{*}c[@r='T1']/{*}is/{*}t")
                self.assertEqual(purchase.text if purchase is not None else None, None if wanted else "Purchased")

    def test_filter_suggestions_rank_folded_and_popular_matches_before_limit(self):
        candidates = filter_candidates([
            "José", "Jose Reader", "Jose Reader", "Jose 10", "Jose 2", "Author Jose", "San Jose",
            "Francojose", "Last Jose Title", "Jose Other Title",
        ])
        self.assertEqual(matching_suggestions(candidates, "jose"), [
            "José", "Jose Reader", "Jose 2", "Jose 10", "Jose Other Title", "Author Jose",
        ])
        self.assertEqual(matching_suggestions(candidates, "title last"), ["Last Jose Title"])
        self.assertNotIn("José", matching_suggestions(candidates, "José"))

    def test_wish_list_uses_title_series_asin_and_individual_authors(self):
        book = dict(asin="MAIN", title="A Story", authors=["Álex", "Brown"], series="Blue Series",
                    subtitle="Hidden Subtitle", narrators=["Frank"])
        for value in ("story", "alex", "brown", "series", "main"):
            self.assertEqual(filter_wishlist([book], value), [book])
        for value in ("alex, brown", "hidden subtitle", "frank"):
            self.assertEqual(filter_wishlist([book], value), [])

    def test_download_toolbar_uses_same_current_batch_eligibility_as_menus(self):
        books = [dict(asin="A", isDownloadable=False)]
        frame = Mock()
        library = SimpleNamespace(frame=frame, selected_books=lambda: books)
        frame.can_add_downloads.return_value = False
        LibraryPanel.download_selection(library)
        frame.review_download.assert_called_once_with(books)
        frame.can_add_downloads.return_value = True
        LibraryPanel.download_selection(library)
        frame.review_add.assert_called_once_with(books)

    def test_removing_last_account_remembers_its_marketplace_from_old_settings(self):
        account = {"id": "account", "marketplace": "ca"}
        frame = SimpleNamespace(settings={"audible_accounts": [account], "audible_account": "account"},
                                save_settings=Mock())
        library = SimpleNamespace(frame=frame, active_account=None)
        LibraryPanel._persist_accounts(library, [], None, removed_account="account")
        self.assertEqual(LibraryPanel.sign_in_marketplace.fget(library), "ca")
        self.assertEqual(frame.settings["audible_accounts"], [])

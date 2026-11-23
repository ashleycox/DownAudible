import csv
import io
import unittest

from downaudible_windows.reading_data import (
    annotation_data,
    annotation_rows,
    filter_annotations,
    goodreads_data,
    goodreads_rows,
)


def csv_rows(data):
    return list(csv.DictReader(io.StringIO(data.decode("utf-8"))))


class GoodreadsExportTests(unittest.TestCase):
    def test_prefers_isbn_and_falls_back_to_asin(self):
        books = [
            {"title": 'A "Story"', "authors": ["Alice", "Renée"], "isbn": "0-8044-2957-x", "asin": "b012345678",
             "isFinished": True, "dateAdded": "2025-12-31T23:30:00Z"},
            {"title": "Another Story", "isbn": "9781234567890", "asin": "b012345679", "percentComplete": 35},
            {"title": "New Story", "isbn": "9781234567897", "asin": "wrong", "percentComplete": 0,
             "dateAdded": "2025-02-30"},
        ]
        ready = csv_rows(goodreads_data(goodreads_rows(books)))
        self.assertEqual(ready[0], {"Title": 'A "Story"', "Author": "Alice, Renée", "ISBN": "080442957X", "ASIN": "",
                                    "Exclusive Shelf": "read", "Date Added": "2025/12/31", "Date Read": ""})
        self.assertEqual((ready[1]["ISBN"], ready[1]["ASIN"], ready[1]["Exclusive Shelf"]),
                         ("", "B012345679", "currently-reading"))
        self.assertEqual((ready[2]["ISBN"], ready[2]["Exclusive Shelf"], ready[2]["Date Added"]),
                         ("9781234567897", "to-read", ""))

    def test_previews_skips_and_keeps_first_matching_edition(self):
        books = [
            {"title": "First", "isbn": "9781234567897", "asin": "B012345678"},
            {"title": "Same ISBN", "isbn": "9781234567897", "asin": "B012345679"},
            {"title": "Same ASIN", "asin": "B012345678", "isFinished": True},
            {"title": "Same alternate ASIN", "asin": "B012345679"},
            {"title": "Missing", "isbn": "9781234567890", "asin": "B-bad"},
        ]
        rows = goodreads_rows(books)
        self.assertEqual([row.status for row in rows],
                         ["Ready", "Duplicate edition", "Duplicate edition", "Duplicate edition", "No valid ISBN or ASIN"])
        exported = csv_rows(goodreads_data(rows))
        self.assertEqual([(row["Title"], row["Exclusive Shelf"]) for row in exported], [("First", "")])

    def test_prevents_spreadsheet_formulas_in_untrusted_titles_and_authors(self):
        exported = csv_rows(goodreads_data(goodreads_rows([
            {"title": "  =1+1", "authors": ["@test"], "asin": "B012345678"},
        ])))
        self.assertEqual((exported[0]["Title"], exported[0]["Author"]), ("'  =1+1", "'@test"))


class AnnotationExportTests(unittest.TestCase):
    def test_orders_known_positions_and_filters_the_complete_note(self):
        rows = annotation_rows([
            {"kind": "note", "text": "Untimed note"},
            {"kind": "bookmark", "positionMilliseconds": 3_661_500, "text": 'A bookmark with a "quote"'},
            {"kind": "note", "positionMilliseconds": 80, "text": "Map\nCafé"},
            {"kind": "unrecognized", "positionMilliseconds": 0, "text": "Ignored"},
        ])
        self.assertEqual([row.position_label for row in rows], ["0:00:00", "1:01:01", ""])
        filtered = filter_annotations(rows, "CAFE map")
        self.assertEqual(csv_rows(annotation_data("Demo", filtered, ".csv")),
                         [{"Type": "Note", "Position": "0:00:00", "Text": "Map\nCafé"}])

    def test_csv_escapes_formulas_and_markdown_keeps_note_literals(self):
        note = '=1+1\n<script>alert("example")</script>'
        rows = annotation_rows([{"kind": "note", "positionMilliseconds": 1_000, "text": note}])
        self.assertEqual(csv_rows(annotation_data("Title", rows, ".csv"))[0]["Text"], "'" + note)
        markdown = annotation_data("Title & Notes", rows, ".md").decode("utf-8")
        self.assertTrue(markdown.startswith("# Title \\& Notes\n"))
        self.assertIn('\n    =1+1\n    <script>alert("example")</script>', markdown)

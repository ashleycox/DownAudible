import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from xml.etree import ElementTree
from zipfile import ZipFile

from downaudible_windows.archive import ArchiveLayout
from downaudible_windows.cue import cue_sheet_data, write_cue_sheet
from downaudible_windows.media import AudioProbe, MediaError
from downaudible_windows.spreadsheet import workbook_data


def probe(*starts):
    return AudioProbe({
        "streams": [{"codec_type": "audio", "duration": "5000"}],
        "format": {"tags": {"TITLE": "Sample Book", "artist": "Alex"}},
        "chapters": [{"start_time": start, "tags": {"title": 'An "Example"\nChapter'}} for start in starts],
    })


class OutputExportTests(unittest.TestCase):
    def test_excel_workbook_preserves_text_and_types_without_formulas(self):
        report = workbook_data(
            ["ASIN", "Title", "Duration (Seconds)", "Finished"],
            [["001100", '=HYPERLINK("sample") <&> _x000D_\r\n\x01', 123.5, False]], title="Library",
        )
        with ZipFile(io.BytesIO(report)) as workbook:
            self.assertIsNone(workbook.testzip())
            workbook_xml = ElementTree.fromstring(workbook.read("xl/workbook.xml"))
            self.assertEqual(workbook_xml.find(".//{*}sheet").get("name"), "Library")
            content = ElementTree.fromstring(workbook.read("xl/worksheets/sheet1.xml"))
        self.assertIsNone(content.find(".//{*}f"))
        self.assertEqual(content.find(".//{*}c[@r='A2']/{*}is/{*}t").text, "001100")
        self.assertEqual(content.find(".//{*}c[@r='B2']/{*}is/{*}t").text,
                         '=HYPERLINK("sample") <&> _x005F_x000D__x000D_\n_x0001_')
        self.assertEqual(content.find(".//{*}c[@r='C2']/{*}v").text, "123.5")
        boolean = content.find(".//{*}c[@r='D2']")
        self.assertEqual((boolean.get("t"), boolean.find("{*}v").text), ("b", "0"))
        self.assertEqual(content.find("{*}autoFilter").get("ref"), "A1:D2")

    def test_cue_uses_embedded_offsets_and_keeps_existing_sheets(self):
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / "Example.m4b"
            audio.write_bytes(b"demo audio")
            inspection = probe("0.000000", "62.020000", "3700.013333")
            tools = SimpleNamespace(probe=lambda *_args, **_kwargs: inspection)
            first = write_cue_sheet(audio, tools)
            second = write_cue_sheet(audio, tools)
            self.assertEqual(first.name, "Example.m4b.cue")
            self.assertEqual(second.name, "Example.m4b (2).cue")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            text = first.read_text(encoding="utf-8")
            self.assertIn('FILE "Example.m4b" WAVE', text)
            self.assertIn('TITLE "An ”Example” Chapter"', text)
            for offset in ("00:00:00", "01:02:02", "61:40:01"):
                self.assertIn(f"INDEX 01 {offset}", text)

    def test_cue_rejects_absent_or_unrepresentable_chapters(self):
        for values in ((), ("0", "0.0001"), ("0", "-1"), ("0", "5000"), ("0", "invalid"), ("0",) * 100):
            with self.subTest(values=values[:4]), self.assertRaises(MediaError):
                cue_sheet_data(Path("Example.mp3"), probe(*values))

    def test_optional_name_parts_keep_existing_template_and_part_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            layout = ArchiveLayout(root, r"{format}\{?series|{series}}\{author}",
                                   "{?series|{series} - Part {partNumber} - }{title}")
            self.assertTrue(layout.is_valid)
            book = {"title": "Example", "author": "Alex", "series": "Shelf"}
            has_series = layout.destination(book, "m4b", part_number=2)
            self.assertEqual(has_series.relative_to(root).parts, ("m4b", "Shelf", "Alex", "Shelf - Part 02 - Example.m4b"))
            no_series = layout.destination(dict(book, series=" "), "m4b", part_number=2)
            self.assertEqual(no_series.relative_to(root).parts, ("m4b", "Alex", "Example - Part 2.m4b"))
            for invalid in ("{?series|../{series}}", "{?invalid|{series}}", "{?series|{invalid}}", "{?series|{?asin|x}}"):
                with self.subTest(invalid=invalid):
                    self.assertFalse(ArchiveLayout(root, invalid).is_valid)
            self.assertEqual(ArchiveLayout(root, "{series}").directory(book | {"series": ""}, "m4b").name, "Unknown")

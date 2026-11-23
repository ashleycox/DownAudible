"""Verify native folder-template presentation and archive recovery compatibility."""

from copy import deepcopy
from dataclasses import asdict
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event
from unittest import TestCase
from unittest.mock import Mock

from downaudible_windows.archive import ArchiveError, ArchiveLayout
from downaudible_windows.jobs import JobRunner, stable_id
from downaudible_windows.state import (
    DEFAULT_FOLDER_TEMPLATE,
    DEFAULTS,
    api_options,
    load_settings,
    write_json,
)

BOOK = {"asin": "DEMO000001", "title": "Sample Book", "authors": ["Example Author"]}
SLASH_TEMPLATE = "{format}/{author}/{title}"


class FolderTemplateTests(TestCase):
    def test_native_and_legacy_templates_make_the_same_layout_and_path(self):
        with TemporaryDirectory() as folder:
            expected = Path("m4b", "Example Author", "Sample Book", "Sample Book.m4b")
            legacy = ArchiveLayout(folder, folder_template=SLASH_TEMPLATE)
            for template in (DEFAULT_FOLDER_TEMPLATE, r"{format}/{author}\{title}", SLASH_TEMPLATE):
                with self.subTest(template=template):
                    layout = ArchiveLayout(folder, folder_template=template)
                    self.assertEqual(asdict(layout), asdict(legacy))
                    self.assertEqual(layout.destination(BOOK, "m4b").relative_to(layout.root), expected)

    def test_saved_template_displays_native_separators(self):
        with TemporaryDirectory() as folder:
            settings_path = Path(folder) / "Settings.json"
            self.assertEqual(load_settings(settings_path)["folder_template"], DEFAULT_FOLDER_TEMPLATE)
            write_json(settings_path, {"folder_template": r"{format}/{author}\{title}"})
            self.assertEqual(load_settings(settings_path)["folder_template"], DEFAULT_FOLDER_TEMPLATE)

    def test_empty_folder_components_and_traversal_remain_invalid(self):
        with TemporaryDirectory() as folder:
            for template in (r"\{title}", "{title}\\", r"{author}\\{title}", r"{author}/\{title}",
                             r"..\{title}", r"{author}\../{title}", r"{author}\.\{title}"):
                with self.subTest(template=template):
                    layout = ArchiveLayout(folder, folder_template=template)
                    self.assertFalse(layout.is_valid)
                    with self.assertRaises(ArchiveError):
                        layout.destination(BOOK, "m4b")

    def test_either_separator_is_invalid_in_filename_templates(self):
        with TemporaryDirectory() as folder:
            for key in ("filename_template", "chapter_filename_template"):
                for template in ("{author}/{title}", r"{author}\{title}"):
                    with self.subTest(key=key, template=template):
                        layout = ArchiveLayout(folder, **{key: template})
                        self.assertFalse(layout.is_valid)

    def test_recognizes_slash_recipe_from_an_older_companion_receipt(self):
        with TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            settings = deepcopy(DEFAULTS)
            settings["archive_root"] = str(root / "Audiobooks")
            options = {**settings["download"], "downloadAudio": False, "downloadChapters": True}
            job = {
                "id": "fixture",
                "kind": "Download",
                "book": BOOK,
                "account_id": "example",
                "options": options,
            }
            layout = ArchiveLayout.from_settings(settings)
            companion = layout.destination(BOOK, "json", folder_format="extras", name_suffix=" - Chapters")
            write_json(companion, {"chapters": []})
            legacy_id = stable_id(
                job["account_id"], BOOK["asin"], str(layout.root), SLASH_TEMPLATE,
                settings["filename_template"], settings["chapter_filename_template"],
                api_options(settings), options, settings["conversion"],
            )
            write_json(root / "Receipts" / f"{legacy_id}.json", {
                "files": [str(companion)],
                "sizes": {str(companion): companion.stat().st_size},
                "groups": {"chapters": [str(companion)]},
                "completed": ["chapters"],
            })
            client = Mock()
            files, warnings = JobRunner(root, client, Mock()).run(job, settings, Event(), Mock())
            self.assertEqual(files, [companion])
            self.assertEqual(warnings, [])
            client.run.assert_not_called()

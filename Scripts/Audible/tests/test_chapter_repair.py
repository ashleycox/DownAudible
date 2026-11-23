import json
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

from audible_helper import execute
from chapter_repair import chapter_repair, fetch_chapter_repair
from download_transfer import OperationError

ASIN = "B000000008"
METADATA = {
    "content_metadata": {
        "content_reference": {"asin": ASIN},
        "chapter_info": {
            "is_accurate": True,
            "runtime_length_ms": 4000,
            "brandIntroDurationMs": 250,
            "brandOutroDurationMs": 500,
            "chapters": [{
                "title": "Part 1",
                "chapters": [
                    {"start_offset_ms": 0, "length_ms": 2000, "title": "The Beginning"},
                    {"start_offset_ms": 2000, "length_ms": 2000, "title": "The Ending"},
                ],
            }],
        },
    },
}


class ChapterRepairTests(unittest.IsolatedAsyncioTestCase):
    async def test_local_json_works_without_a_session_and_separates_announcements(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "book-chapters.json"
            path.write_text(json.dumps(METADATA), encoding="utf-8")
            result = await execute({"command": "chapterRepair", "file": str(path), "asin": ASIN})
        self.assertEqual(result["asin"], ASIN)
        self.assertEqual(result["runtimeMilliseconds"], 4000)
        self.assertEqual([row["title"] for row in result["chapters"]], ["The Beginning", "The Ending"])
        markers = result["separatedChapters"]
        self.assertEqual([row["title"] for row in markers], ["Audible Intro", "The Beginning", "The Ending", "Audible Outro"])
        self.assertEqual([(row["startMilliseconds"], row["durationMilliseconds"]) for row in markers],
                         [(0, 250), (250, 1750), (2000, 1500), (3500, 500)])

    async def test_fetch_uses_title_and_flat_chapters(self):
        fetch = AsyncMock(return_value=METADATA)
        with patch("chapter_repair.LibraryItem", return_value=Mock(get_content_metadata=fetch)) as item:
            report = await fetch_chapter_repair("fixture", ASIN, "best")
        item.assert_called_once_with({"asin": ASIN}, "fixture")
        fetch.assert_awaited_once_with("best", chapter_type="Flat")
        self.assertEqual(report["asin"], ASIN)

    def test_rejects_wrong_edition_inaccurate_runtime_and_overlap(self):
        with self.assertRaisesRegex(OperationError, "chapterRepairEdition"):
            chapter_repair(METADATA, expected_asin="B000000009")
        for key, value in (("is_accurate", False), ("runtime_length_ms", 3999)):
            metadata = deepcopy(METADATA)
            metadata["content_metadata"]["chapter_info"][key] = value
            with self.assertRaisesRegex(OperationError, "chapterRepairMetadata"):
                chapter_repair(metadata)
        metadata = deepcopy(METADATA)
        metadata["content_metadata"]["chapter_info"]["chapters"][0]["chapters"][1]["start_offset_ms"] = 1999
        with self.assertRaisesRegex(OperationError, "chapterRepairMetadata"):
            chapter_repair(metadata)

import json
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from audible.exceptions import NotFoundError, Unauthorized
from audible_helper import execute
from download_transfer import OperationError

ASIN = "B000000001"
REQUEST = {
    "command": "annotations",
    "session": json.dumps({"locale_code": "uk"}),
    "asin": ASIN,
}


class AnnotationTests(unittest.IsolatedAsyncioTestCase):
    async def test_keeps_bookmarks_and_notes_in_playback_order(self):
        records = [
            {
                "type": "audible.note",
                "startPosition": "7345000",
                "text": "Keep the café note.\nSecond line.",
            },
            {
                "type": "audible.bookmark",
                "startPosition": "90000",
                "text": "Opening chapter",
                "annotationId": "fixture-private-id",
            },
            {"type": "audible.last_heard", "startPosition": "92000"},
            {
                "type": "audible.clip",
                "startPosition": "120000",
                "metadata": {"note": "Private clip"},
            },
            {"type": "audible.note", "startPosition": "-10", "text": "Unknown time"},
            {"type": [], "startPosition": True},
        ]
        mocked = AsyncMock(return_value={"payload": {"key": ASIN, "records": records}})
        with patch("audible_helper.LibraryItem.get_annotations", new=mocked):
            result = await execute(REQUEST)
        mocked.assert_awaited_once()
        self.assertEqual(
            result,
            {
                "entries": [
                    {
                        "kind": "bookmark",
                        "positionMilliseconds": 90000,
                        "text": "Opening chapter",
                    },
                    {
                        "kind": "note",
                        "positionMilliseconds": 7345000,
                        "text": "Keep the café note.\nSecond line.",
                    },
                    {
                        "kind": "note",
                        "positionMilliseconds": None,
                        "text": "Unknown time",
                    },
                ]
            },
        )

    async def test_unreadable_or_different_book_is_an_error(self):
        for payload in (
            {"key": "B000000002", "records": []},
            {"key": ASIN, "records": {}},
        ):
            with (
                self.subTest(payload=payload),
                patch(
                    "audible_helper.LibraryItem.get_annotations",
                    new=AsyncMock(return_value={"payload": payload}),
                ),
                self.assertRaisesRegex(OperationError, "annotationsResponse"),
            ):
                await execute(REQUEST)

    async def test_missing_annotations_and_rejected_account_differ(self):
        response = httpx.Response(404)
        with patch(
            "audible_helper.LibraryItem.get_annotations",
            new=AsyncMock(side_effect=NotFoundError(response, None)),
        ):
            self.assertEqual(await execute(REQUEST), {"entries": []})
        response = httpx.Response(401)
        with (
            patch(
                "audible_helper.LibraryItem.get_annotations",
                new=AsyncMock(side_effect=Unauthorized(response, None)),
            ),
            self.assertRaises(Unauthorized),
        ):
            await execute(REQUEST)

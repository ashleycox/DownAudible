import asyncio
import tempfile
import unittest
from pathlib import Path

import httpx
from download_transfer import CHUNK_SIZE, OperationError, fingerprint, stream_file


def audio(fill):
    prefix = b"\x00\x00\x00\x20ftypaax "
    return prefix + fill * (2 * CHUNK_SIZE - len(prefix))


ORIGINAL = audio(b"a")
REPLACEMENT = audio(b"b")
URL = "https://cdn.example.test/book?ticket=previous"
NEW_URL = "https://cdn.example.test/book?ticket=renewed"
IDENTITY = fingerprint("aax", "best", "AAX_44_128")


class BrokenBody(httpx.AsyncByteStream):
    def __init__(self, body, stop):
        self.body = body
        self.stop = stop

    async def __aiter__(self):
        yield self.body[: self.stop]
        raise httpx.ReadError("Fixture connection dropped")


class PausedBody(httpx.AsyncByteStream):
    def __init__(self, paused):
        self.paused = paused

    async def __aiter__(self):
        yield ORIGINAL[:CHUNK_SIZE]
        self.paused.set()
        await asyncio.Future()


def whole(body=ORIGINAL, etag='"version-1"', stream=None, disposition=None):
    headers = {"content-type": "audio/aax", "content-length": str(len(body))}
    if etag is not None:
        headers["etag"] = etag
    if disposition is not None:
        headers["content-disposition"] = disposition
    return httpx.Response(
        200, headers=headers, content=body if stream is None else None, stream=stream
    )


def ranged(body=ORIGINAL, etag='"version-1"', start=CHUNK_SIZE):
    return httpx.Response(
        206,
        headers={
            "etag": etag,
            "content-range": f"bytes {start}-{len(body) - 1}/{len(body)}",
        },
        content=body[start:],
    )


class DownloadTransferTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.target = Path(root.name) / "book.aax"
        self.partial = self.target.with_name(self.target.name + ".partial")
        self.state = self.target.with_name(self.target.name + ".transfer.json")

    async def transfer(self, mock, url=URL, identity=IDENTITY):
        async with httpx.AsyncClient(transport=httpx.MockTransport(mock)) as client:
            return await stream_file(
                client, url, self.target, "aax", representation=identity
            )

    async def disconnect(self, etag='"version-1"', offset=CHUNK_SIZE, disposition=None):
        with self.assertRaises(httpx.ReadError):
            await self.transfer(
                lambda request: whole(
                    etag=etag, stream=BrokenBody(ORIGINAL, offset), disposition=disposition
                )
            )
        self.assertTrue(self.partial.is_file())
        self.assertEqual(self.partial.stat().st_size, offset)
        self.assertFalse(self.target.exists())

    async def test_resumes_with_matching_strong_validator_and_renews_signed_query(self):
        await self.disconnect(disposition='attachment; filename="Audible Title.AAX"')
        self.assertNotIn("ticket=previous", self.state.read_text())

        def resume(request):
            self.assertEqual(request.headers["Range"], f"bytes={CHUNK_SIZE}-")
            self.assertEqual(request.headers["If-Range"], '"version-1"')
            self.assertEqual(request.headers["Accept-Encoding"], "identity")
            return ranged()

        result = await self.transfer(resume, NEW_URL)
        self.assertEqual(result.path, self.target)
        self.assertEqual(result.original_filename, "Audible Title.AAX")
        self.assertEqual(self.target.read_bytes(), ORIGINAL)
        self.assertFalse(self.partial.exists())
        cached = await self.transfer(lambda request: self.fail("Completed stage fetched again"))
        self.assertEqual(cached.path, result.path)
        self.assertEqual(cached.original_filename, result.original_filename)
        self.assertEqual(result.transferred_bytes, len(ORIGINAL) - CHUNK_SIZE)
        self.assertEqual(cached.transferred_bytes, 0)

    async def test_aax_name_prefers_disposition_then_uses_a_safe_url_basename(self):
        cases = [
            ('attachment; filename="Book; Volume II.AAX"', "generic", "Book; Volume II.AAX"),
            ("inline; FILENAME=Book.aax", "generic", "Book.aax"),
            (
                'attachment; filename="Alternate.aax"; filename*=UTF-8\'\'%C3%89cho.aax',
                "Streaming.aax",
                "Écho.aax",
            ),
            (
                'attachment; filename*=UTF-8\'\'%FF.aax; filename="Alternate.aax"',
                "Streaming.aax",
                "Alternate.aax",
            ),
            (
                'attachment; filename="../Escape.aax"',
                "Streaming%20Title.aax",
                "Streaming Title.aax",
            ),
            ('attachment; filename*=UTF-8\'\'folder%5Cescape.aax', "generic", None),
            ('attachment; filename="Different.mp3"', "folder%2Fescape.aax", None),
            ('attachment; filename="Unterminated.aax', "Streaming.aax", "Streaming.aax"),
            ('attachment; filename*=UTF-8\'\'Bad%GG.aax', "Bad%GG.aax", None),
            ('attachment; filename=First.aax; filename=Second.aax', "generic", None),
            ('attachment; filename="Book.aax.transfer.json"', "generic", None),
            ('attachment; filename="Book.aax.partial"', "generic", None),
        ]
        for disposition, path, expected in cases:
            with self.subTest(disposition=disposition, path=path):
                result = await self.transfer(
                    lambda request: whole(disposition=disposition),
                    url=f"https://cdn.example.test/{path}?ticket=hidden.aax",
                    identity=None,
                )
                self.assertEqual(result.original_filename, expected)
                self.assertEqual(result.path, self.target)

    async def test_cancellation_keeps_written_prefix(self):
        paused = asyncio.Event()
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda request: whole(stream=PausedBody(paused))
            ),
        ) as client:
            transfer = asyncio.create_task(
                stream_file(client, URL, self.target, "aax", representation=IDENTITY),
            )
            await asyncio.wait_for(paused.wait(), timeout=2)
            transfer.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await transfer
        self.assertEqual(self.partial.read_bytes(), ORIGINAL[:CHUNK_SIZE])
        self.assertTrue(self.state.exists())

    async def test_200_response_replaces_partial_with_full_body(self):
        await self.disconnect()

        def changed(request):
            self.assertIn("Range", request.headers)
            return whole(REPLACEMENT, etag='"version-2"')

        await self.transfer(changed, NEW_URL)
        self.assertEqual(self.target.read_bytes(), REPLACEMENT)

    async def test_invalid_206_requires_a_full_request(self):
        await self.disconnect()
        sequence = []

        def invalid_range(request):
            sequence.append(request.headers.get("Range"))
            if len(sequence) == 1:
                return ranged(REPLACEMENT, start=CHUNK_SIZE + 1)
            return whole(REPLACEMENT, etag='"version-2"')

        await self.transfer(invalid_range)
        self.assertEqual(sequence, [f"bytes={CHUNK_SIZE}-", None])
        self.assertEqual(self.target.read_bytes(), REPLACEMENT)

    async def test_206_from_a_different_resource_cannot_resume(self):
        await self.disconnect()
        sequence = []

        def changed_path(request):
            sequence.append(request.headers.get("Range"))
            return ranged(REPLACEMENT) if len(sequence) == 1 else whole(REPLACEMENT)

        await self.transfer(changed_path, "https://cdn.example.test/replacement")
        self.assertEqual(sequence, [f"bytes={CHUNK_SIZE}-", None])
        self.assertEqual(self.target.read_bytes(), REPLACEMENT)

    async def test_weak_validator_or_missing_metadata_forces_full_request(self):
        await self.disconnect(etag='W/"weak"')

        def fresh(request):
            self.assertNotIn("Range", request.headers)
            return whole(REPLACEMENT)

        await self.transfer(fresh)
        self.assertEqual(self.target.read_bytes(), REPLACEMENT)

        self.target.unlink()
        self.state.unlink()
        self.partial.write_bytes(b"Left by an older build")
        await self.transfer(fresh)
        self.assertEqual(self.target.read_bytes(), REPLACEMENT)

    async def test_different_representation_invalidates_partial(self):
        await self.disconnect()

        def fresh(request):
            self.assertNotIn("Range", request.headers)
            return whole(REPLACEMENT)

        await self.transfer(fresh, identity=fingerprint("aax", "normal", "AAX_44_64"))
        self.assertEqual(self.target.read_bytes(), REPLACEMENT)

    async def test_416_promotes_full_partial_with_exact_size_and_validator(self):
        await self.disconnect(offset=len(ORIGINAL))

        def already_complete(request):
            self.assertEqual(request.headers["Range"], f"bytes={len(ORIGINAL)}-")
            return httpx.Response(
                416,
                headers={
                    "etag": '"version-1"',
                    "content-range": f"bytes */{len(ORIGINAL)}",
                },
            )

        await self.transfer(already_complete)
        self.assertEqual(self.target.read_bytes(), ORIGINAL)

    async def test_truncated_range_remains_partial(self):
        await self.disconnect()
        short_size = len(ORIGINAL) - 128
        with self.assertRaisesRegex(OperationError, "incompleteResponse"):
            await self.transfer(
                lambda request: httpx.Response(
                    206,
                    headers={
                        "etag": '"version-1"',
                        "content-range": f"bytes {CHUNK_SIZE}-{len(ORIGINAL) - 1}/{len(ORIGINAL)}",
                        "content-length": str(len(ORIGINAL) - CHUNK_SIZE),
                    },
                    content=ORIGINAL[CHUNK_SIZE:short_size],
                ),
            )
        self.assertEqual(self.partial.read_bytes(), ORIGINAL[:short_size])
        self.assertFalse(self.target.exists())

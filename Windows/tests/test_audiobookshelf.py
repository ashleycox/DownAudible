"""Offline checks for Audiobookshelf requests and durable queued uploads."""

import json
import tempfile
import unittest
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Event, Thread
from unittest.mock import Mock
from urllib.parse import parse_qs, urlsplit

from downaudible_windows.audiobookshelf import (
    ShelfClient,
    ShelfError,
    UploadBook,
    UploadQueue,
    UploadTarget,
    archive_upload,
    normalize_server,
    receipt_index,
    stored_token,
)
from downaudible_windows.state import write_json

DEMO = {"asin": "B012345678", "title": "An Example Book", "authors": ["Demo Author"], "series": "Demo Series"}


class TestServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, handler):
        super().__init__(("127.0.0.1", 0), handler)
        self.responses = {}
        self.requests = []
        self.upload_status = 200


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query).get("q", [""])[0]
        self.server.requests.append(("GET", parsed.path, query, self.headers.get("Authorization")))
        if parsed.path == "/shelf/api/libraries":
            libraries = [
                {"id": "pod", "name": "Podcasts", "mediaType": "podcast", "folders": [{"id": "pf", "fullPath": "/pod"}]},
                {"id": "lib", "name": "Books", "mediaType": "book", "folders": [{"id": "folder", "fullPath": "/books"}]},
            ]
            self.send_json(200, {"libraries": libraries})
        elif parsed.path == "/shelf/api/libraries/lib/search":
            response = self.server.responses.get(query, {"book": []})
            self.send_json(200, response)
        elif parsed.path == "/api/libraries":
            self.send_response(302)
            self.send_header("Location", self.server.server_origin + "/shelf/api/libraries")
            self.end_headers()
        else:
            self.send_json(404, {})

    def do_POST(self):
        self.server.requests.append(("POST", self.path, "", self.headers.get("Authorization")))
        self.server.payload = self.rfile.read(int(self.headers["Content-Length"]))
        self.server.content_type = self.headers["Content-Type"]
        self.send_json(self.server.upload_status, {})

    def send_json(self, code, data):
        document = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(document)))
        self.end_headers()
        self.wfile.write(document)

    def log_message(self, _format, *_args):
        pass


class AudiobookshelfTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.root = Path(directory).resolve()
        self.audio = self.root / "Book – Audio.m4b"
        self.cover = self.root / "Book cover.png"
        self.pdf = self.root / "Companion.pdf"
        for path in (self.audio, self.cover, self.pdf):
            path.write_bytes(path.name.encode())
        self.book = UploadBook.prepare(DEMO, [self.audio], [self.cover], [self.pdf])
        self.server = self.enterContext(TestServer(Handler))
        self.server.server_origin = f"http://127.0.0.1:{self.server.server_port}"
        self.target = UploadTarget(self.server.server_origin + "/shelf", "lib", "folder", "Books", "/books")
        self.client = ShelfClient(self.target.server, "offline-token")
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.shutdown)

    def test_server_normalizes_subpath_and_never_follows_redirect(self):
        self.assertEqual(normalize_server("HTTPS://BOOKS.EXAMPLE:443/my-shelf/"), "https://books.example/my-shelf")
        with self.assertRaisesRegex(ShelfError, "Use HTTPS"):
            normalize_server("http://books.example")
        with self.assertRaisesRegex(ShelfError, "username"):
            normalize_server("https://user@books.example")
        with self.assertRaisesRegex(ShelfError, "redirected"):
            ShelfClient(self.server.server_origin, "first-origin").libraries()
        self.assertEqual(self.server.requests, [("GET", "/api/libraries", "", "Bearer first-origin")])

    def test_saved_token_is_available_only_to_its_original_server_origin(self):
        client = Mock(demo=False)
        client.session.return_value = json.dumps({"origin": "https://books.example", "token": "offline-token"})
        self.assertEqual(stored_token(client, "https://books.example/new-proxy-path"), "offline-token")
        self.assertEqual(stored_token(client, "https://books.example:1234"), "")
        self.assertEqual(stored_token(client, "https://other.example"), "")

    def test_discovers_only_book_folders_and_streams_audio_cover_and_optional_pdf(self):
        libraries = self.client.libraries()
        self.assertEqual([(item.id, item.folders[0].id) for item in libraries], [("lib", "folder")])
        self.assertEqual(self.client.upload(self.target, self.book, Event(), include_pdf=False), "Sent to server")
        self.assertEqual(self.server.requests[-1], ("POST", "/shelf/api/upload", "", "Bearer offline-token"))
        self.assertEqual(self._uploaded_files(), [self.audio.name, self.cover.name])
        self.client.upload(self.target, self.book, Event(), include_pdf=True)
        self.assertEqual(self._uploaded_files(), [self.audio.name, self.cover.name, self.pdf.name])

    def _uploaded_files(self):
        document = (f"Content-Type: {self.server.content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode()
                    + self.server.payload)
        contents = BytesParser(policy=policy.default).parsebytes(document)
        fields = dict((item.get_param("name", header="content-disposition"), item.get_content())
                      for item in contents.iter_parts() if not item.get_filename())
        self.assertEqual(fields, {"library": "lib", "folder": "folder", "title": "An Example Book",
                                  "author": "Demo Author", "series": "Demo Series"})
        files = [item for item in contents.iter_parts() if item.get_filename()]
        self.assertEqual([item.get_param("name", header="content-disposition") for item in files],
                         [f"file{index}" for index in range(len(files))])
        return [item.get_filename() for item in files]

    def test_duplicate_by_asin_skips_upload_and_edition_cannot_overwrite(self):
        def result(asin, title=DEMO["title"]):
            return {"book": [{"libraryItem": {"media": {"metadata": {
                "asin": asin, "title": title, "authorName": "Demo Author",
            }}}}]}
        self.server.responses[DEMO["asin"]] = result(DEMO["asin"], title="Renamed on server")
        self.assertEqual(self.client.upload(self.target, self.book, Event()), "Already in library")
        self.server.responses.pop(DEMO["asin"])
        self.server.responses[DEMO["title"]] = result("B098765432")
        with self.assertRaisesRegex(ShelfError, "different edition"):
            self.client.upload(self.target, self.book, Event())
        self.assertTrue(all(record[0] == "GET" for record in self.server.requests))

    def test_local_revision_change_is_not_uploaded(self):
        self.audio.write_bytes(b"shorter")
        with self.assertRaisesRegex(ShelfError, "A saved file changed"):
            self.client.upload(self.target, self.book, Event())
        self.assertTrue(all(record[0] == "GET" for record in self.server.requests))

    def test_backfill_picks_complete_converted_audio_and_existing_companions(self):
        directory = self.root / "Receipts"
        originals = self.root / "Original.mp3"
        originals.write_bytes(b"audio")
        write_json(directory / "conversion.json", {
            "account_id": "fixture", "root": str(self.root), "asin": DEMO["asin"],
            "groups": {"conversion": [str(self.audio)], "cover": [str(self.cover)]},
            "sizes": {str(self.audio): self.audio.stat().st_size},
        })
        write_json(directory / "original.json", {
            "account_id": "fixture", "root": str(self.root), "asin": DEMO["asin"],
            "groups": {"audio": [str(originals)], "pdf": [str(self.pdf)]},
        })
        index = receipt_index(directory, "fixture", self.root)
        book = archive_upload(DEMO, index[DEMO["asin"]], self.root, include_pdf=True)
        self.assertEqual([file.path for file in book.files], list(map(str, (self.audio, self.cover, self.pdf))))

    def test_failed_upload_stays_in_queue_and_user_can_retry_it_after_restart(self):
        store = self.root / "Shelf.json"
        changed = Event()
        self.server.upload_status = 403
        first = UploadQueue(store, changed=lambda *_: changed.set())
        self.addCleanup(first.close)
        first.configure(self.target, "offline-token")
        self.assertEqual(first.enqueue([self.book]), 1)
        self.assertTrue(changed.wait(3))
        self.assertEqual(first.snapshot()[0]["status"], "Failed")
        self.assertNotIn("offline-token", store.read_text())
        first.close()
        first.worker.join(3)
        changed.clear()
        second = UploadQueue(store, changed=lambda *_: changed.set())
        self.addCleanup(second.close)
        wrong = UploadTarget(self.target.server, self.target.library_id, "other", "Books", "/other")
        second.configure(wrong, "offline-token")
        self.assertEqual(second.retry(set()), 0)
        second.configure(self.target, "offline-token")
        self.server.upload_status = 200
        self.assertEqual(second.retry(set()), 1)
        self.assertTrue(changed.wait(3))
        self.assertEqual(second.snapshot()[0]["status"], "Sent")
        self.assertEqual(second.enqueue([self.book]), 0)

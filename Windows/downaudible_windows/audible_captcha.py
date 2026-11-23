"""Load a bounded Audible sign-in challenge image without persisting its URL."""

from __future__ import annotations

import time
from http.client import HTTPException
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, build_opener

MAX_BYTES = 512 * 1024
MAX_WIDTH = 1600
MAX_HEIGHT = 800
JPEG_FRAME_MARKERS = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def valid_image_url(url):
    if not isinstance(url, str):
        return False
    try:
        parsed = urlsplit(url)
        return parsed.scheme == "https" and bool(parsed.hostname) and parsed.username is None
    except ValueError:
        return False


class HTTPSRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if valid_image_url(newurl):
            return super().redirect_request(req, fp, code, msg, headers, newurl)
        return None


def captcha_image_data(url, cancel):
    if not valid_image_url(url) or cancel.is_set():
        return None
    deadline = time.monotonic() + 8
    content = bytearray()
    try:
        with build_opener(HTTPSRedirect()).open(url, timeout=4) as response:
            while len(content) <= MAX_BYTES and not cancel.is_set() and time.monotonic() < deadline:
                part = response.read1(min(16_384, MAX_BYTES + 1 - len(content)))
                if not part:
                    result = bytes(content)
                    return result if image_is_small(result) else None
                content.extend(part)
    except (OSError, ValueError, HTTPException):
        pass
    return None


def image_is_small(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR") and len(data) >= 24:
        width = int.from_bytes(data[16:20])
        height = int.from_bytes(data[20:24])
    elif data.startswith(b"\xff\xd8"):
        width, height = jpeg_size(data)
    else:
        return False
    return 0 < width <= MAX_WIDTH and 0 < height <= MAX_HEIGHT


def jpeg_size(data):
    cursor = 2
    while cursor + 3 < len(data) and data[cursor] == 0xFF:
        cursor += 1
        marker = data[cursor]
        if marker == 0xFF:
            continue
        if marker in {0xDA, 0xD9}:
            break
        size = int.from_bytes(data[cursor + 1:cursor + 3])
        if size < 2 or cursor + 1 + size > len(data):
            break
        if marker in JPEG_FRAME_MARKERS and size >= 8:
            height = int.from_bytes(data[cursor + 4:cursor + 6])
            width = int.from_bytes(data[cursor + 6:cursor + 8])
            return width, height
        cursor += 1 + size
    return 0, 0

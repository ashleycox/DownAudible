from io import BytesIO
from threading import Event
from unittest import TestCase
from unittest.mock import patch

from downaudible_windows.audible_captcha import (
    MAX_BYTES,
    MAX_WIDTH,
    HTTPSRedirect,
    captcha_image_data,
    image_is_small,
    valid_image_url,
)


def png_header(width, height):
    return (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
        + width.to_bytes(4)
        + height.to_bytes(4)
    )


class CaptchaTests(TestCase):
    def test_bounded_png_and_jpeg_dimensions(self):
        self.assertTrue(image_is_small(png_header(250, 60)))
        self.assertFalse(image_is_small(png_header(MAX_WIDTH + 1, 1)))
        self.assertFalse(image_is_small(png_header(25, 0)))
        jpeg = b"\xff\xd8\xff\xc0\x00\x08\x08\x00\x10\x00\x20\x01\xff\xd9"
        self.assertTrue(image_is_small(jpeg))
        self.assertFalse(image_is_small(jpeg[:7]))

    def test_download_size_and_scheme(self):
        data = png_header(200, 40)
        event = Event()
        url = "https://example.com/verification"
        with patch("downaudible_windows.audible_captcha.build_opener") as opener:
            opener.return_value.open.side_effect = [
                BytesIO(data),
                BytesIO(data.ljust(MAX_BYTES + 1, b"0")),
            ]
            self.assertEqual(captcha_image_data(url, event), data)
            self.assertIsNone(captcha_image_data(url, event))
            self.assertIsNone(captcha_image_data("http://example.com/", event))
            event.set()
            self.assertIsNone(captcha_image_data(url, event))
            self.assertEqual(opener.call_count, 2)

    def test_rejects_unsecured_or_credentialed_redirects(self):
        self.assertFalse(valid_image_url("https://user:password@example.com/"))
        redirect = HTTPSRedirect()
        self.assertIsNone(
            redirect.redirect_request(None, None, 302, "", {}, "http://example.com/")
        )

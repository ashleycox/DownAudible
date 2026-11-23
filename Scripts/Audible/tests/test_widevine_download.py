import base64
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from uuid import UUID

import httpx
from Crypto.PublicKey import RSA
from pywidevine.device import Device, DeviceTypes
from pywidevine.license_protocol_pb2 import (
    ClientIdentification, DrmCertificate, SignedDrmCertificate,
)
from pywidevine.pssh import PSSH

from audible_helper import check_license_response, download_audio, failure_code
from download_transfer import OperationError
from widevine_download import (
    ANDROID_DEVICE_TYPE,
    PROVISIONER,
    WidevineDownload,
    WidevineUnavailable,
    chapter_metadata,
    parse_manifest,
    provision,
)

ASIN = "B000000001"
KID = UUID("11223344-5566-7788-9900-aabbccddeeff")
SOURCE = httpx.URL("https://cdn.invalid/library/manifest.mpd")
PSSH_XML = f"""
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013">
 <Period>
  <AdaptationSet>
   <ContentProtection cenc:default_KID="{KID}" schemeIdUri="urn:mpeg:dash:mp4protection:2011"/>
   <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
     <cenc:pssh>{PSSH.new(PSSH.SystemId.Widevine, key_ids=[KID]).dumps()}</cenc:pssh>
   </ContentProtection>
   <Representation><BaseURL>media.m4a</BaseURL><SegmentBase indexRange="0-100"/></Representation>
  </AdaptationSet>
 </Period>
</MPD>
"""


def registration(device=ANDROID_DEVICE_TYPE, extra_headers=None):
    def sign(request):
        request.headers.update({
            "x-adp-token": "fixture-adp",
            "x-adp-alg": "fixture-alg",
            "x-adp-signature": "fixture-signature",
        })
        request.headers.update(extra_headers or {})

    return SimpleNamespace(
        locale=SimpleNamespace(domain="co.uk"),
        device_info={"device_type": device},
        adp_token="fixture-adp",
        device_private_key="not sent",
        access_token="audible-only",
        expires=1700000000,
        access_token_expired=False,
        refresh_token="not sent",
        sign_request=sign,
    )


def transport_factory(respond):
    # Capture the original class before the production module's attribute is patched.
    original = httpx.AsyncClient

    def client(**arguments):
        return original(transport=httpx.MockTransport(respond), **arguments)

    return client


class WidevineTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        key = RSA.generate(1024).export_key(format="DER")
        certificate = DrmCertificate(system_id=1)
        signed = SignedDrmCertificate(drm_certificate=certificate.SerializeToString())
        client = ClientIdentification(token=signed.SerializeToString())
        cls.device = Device(
            type_=DeviceTypes.ANDROID, security_level=3, flags=None, private_key=key,
            client_id=client.SerializeToString(),
        ).dumps()
        cls.encoded = base64.b64encode(cls.device).decode("ascii")

    async def test_consent_and_registration_required_before_network(self):
        with patch("widevine_download.httpx.AsyncClient") as http:
            for consent, device, code in (
                (False, ANDROID_DEVICE_TYPE, "widevineConsent"),
                (1, ANDROID_DEVICE_TYPE, "widevineConsent"),
                (True, "not-android", "widevineRegistration"),
            ):
                with self.subTest(code=code), self.assertRaises(OperationError) as caught:
                    await provision(registration(device), consent, 20)
                self.assertEqual(caught.exception.code, code)
            http.assert_not_called()

    async def test_broker_request_is_limited_to_signed_account_information(self):
        def handler(request):
            self.assertEqual((request.method, str(request.url)), ("POST", PROVISIONER))
            self.assertNotIn("Authorization", request.headers)
            self.assertNotIn("Cookie", request.headers)
            self.assertEqual(json.loads(request.content), {
                "Url": "https://api.audible.co.uk/1.0/account/information",
                "Headers": {
                    "x-adp-token": "fixture-adp",
                    "x-adp-alg": "fixture-alg",
                    "x-adp-signature": "fixture-signature",
                },
            })
            return httpx.Response(200, content=self.device)

        with patch("widevine_download.httpx.AsyncClient", transport_factory(handler)):
            auth = registration(extra_headers={"x-amz-access-token": "restricted", "Cookie": "restricted"})
            self.assertEqual(await provision(auth, True, 20), {"cdm": self.encoded})

    async def test_broker_redirect_never_receives_credentials(self):
        seen = []

        def handler(request):
            seen.append(str(request.url))
            return httpx.Response(307, headers={"Location": "https://rogue.invalid"})

        with (
            patch("widevine_download.httpx.AsyncClient", transport_factory(handler)),
            self.assertRaises(OperationError) as caught,
        ):
            await provision(registration(), True, 20)
        self.assertEqual(caught.exception.code, "widevineProvision")
        self.assertEqual(seen, [PROVISIONER])

    async def test_license_sends_bearer_to_audible_and_honors_fallback(self):
        extensions = (
            (200, {"content_license": {"status_code": "Granted", "drm_type": "Mpeg"}}, None),
            (404, {"error_code": "000307"}, None),
            (403, {}, "requestRejected"),
            (429, {}, "rateLimited"),
            (503, {}, "serverUnavailable"),
            (200, {"content_license": {"status_code": "Denied", "drm_type": "Mpeg"}}, "licenseDenied"),
            (200, {"content_license": {
                "status_code": "Granted", "drm_type": "Widevine",
                "license_response": str(SOURCE),
                "content_metadata": {"content_reference": {"codec": "mp4a.40.42"}},
            }}, "granted"),
        )
        for status, payload, expected in extensions:
            def handler(request):
                self.assertEqual(
                    str(request.url), f"https://api.audible.co.uk/1.0/content/{ASIN}/licenserequest"
                )
                self.assertEqual(request.headers["x-amz-access-token"], "audible-only")
                self.assertEqual(request.headers["x-adp-token"], "fixture-adp")
                self.assertNotIn("Authorization", request.headers)
                data = json.loads(request.content)
                self.assertEqual(data["consumption_type"], "Download")
                self.assertEqual(data["tenant_id"], "Audible")
                self.assertFalse(data["spatial"])
                self.assertFalse(data["supported_media_features"]["previews"])
                return httpx.Response(status, json=payload)

            with (
                self.subTest(status=status, expected=expected),
                tempfile.NamedTemporaryFile() as ffmpeg,
                patch("widevine_download.httpx.AsyncClient", transport_factory(handler)),
            ):
                downloader = WidevineDownload(registration(), self.encoded, ffmpeg.name, 30)
                if expected == "granted":
                    self.assertEqual(
                        await downloader.license(ASIN, "best", check_license_response),
                        payload["content_license"],
                    )
                elif expected is None:
                    with self.assertRaises(WidevineUnavailable):
                        await downloader.license(ASIN, "best", check_license_response)
                else:
                    with self.assertRaises(Exception) as caught:
                        await downloader.license(ASIN, "best", check_license_response)
                    self.assertEqual(failure_code(caught.exception), expected)

    async def test_entitlement_and_explicit_source_choices_skip_widevine(self):
        item = SimpleNamespace(
            asin=ASIN, is_published=lambda: True, content_delivery_type="SinglePartBook",
            customer_rights={"is_consumable_offline": False},
        )
        widevine = SimpleNamespace(download=AsyncMock())
        with self.assertRaises(OperationError) as caught:
            await download_audio(item, None, None, Path.cwd(), None, {}, widevine)
        self.assertEqual(caught.exception.code, "offlineRestricted")
        item.customer_rights["is_consumable_offline"] = True
        item.get_aax_url_old = AsyncMock(side_effect=OperationError("skipFixture"))
        item.get_aax_url = AsyncMock()
        item.get_aaxc_url = AsyncMock(side_effect=OperationError("skipFixture"))
        for mode in ("aaxOnly", "aaxcOnly"):
            with self.subTest(mode=mode), self.assertRaises(OperationError) as caught:
                await download_audio(item, None, None, Path.cwd(), None, {"format": mode}, widevine)
            self.assertEqual(caught.exception.code, "skipFixture")
        widevine.download.assert_not_awaited()

    def test_parse_only_complete_verified_manifest(self):
        manifest = parse_manifest(PSSH_XML.encode(), SOURCE)
        self.assertEqual(str(manifest.url), "https://cdn.invalid/library/media.m4a")
        self.assertEqual(manifest.kid, KID)
        self.assertEqual(manifest.pssh.system_id, PSSH.SystemId.Widevine)
        for document in (
            '<!DOCTYPE MPD [<!ENTITY bad "at most one byte">]>' + PSSH_XML.strip(),
            PSSH_XML.replace("media.m4a", "http://cdn.invalid/media.m4a"),
            PSSH_XML.replace("<SegmentBase", "<SegmentTemplate"),
            PSSH_XML.replace("<SegmentBase", "<BaseURL>other.m4a</BaseURL><SegmentBase"),
            PSSH_XML.replace("<cenc:pssh>", "<cenc:pssh>?!"),
        ):
            with self.subTest(document=document), self.assertRaises(OperationError) as caught:
                parse_manifest(document.encode(), SOURCE)
            self.assertEqual(caught.exception.code, "widevineManifest")

    def test_chapter_titles_use_plain_metadata(self):
        metadata = chapter_metadata([
            {"title": "Title #1\nMore=Yes", "startMilliseconds": 36, "durationMilliseconds": 864}
        ])
        self.assertEqual(
            metadata,
            ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=36\nEND=900\ntitle=Title \\#1 More\\=Yes\n",
        )

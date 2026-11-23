"""Verify account reports without contacting Audible or provisioning Widevine."""

import json
import unittest
from datetime import datetime
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import httpx

from android_sign_in import ANDROID_DEVICE_TYPE
from audible_helper import check_license_response, execute, failure_code
from audible_reports import (
    audio_offers,
    deregister_device,
    device_registration,
    listening_stats,
)
from download_transfer import OperationError
from widevine_download import WidevineUnavailable

ASIN = "B000000001"


def fake_item(**values):
    return SimpleNamespace(
        **{
            "asin": ASIN,
            "customer_rights": {"is_consumable_offline": True},
            "is_published": Mock(return_value=True),
            "is_parent_podcast": Mock(return_value=False),
            "is_ayce": False,
            "_get_codec": Mock(return_value=("AAX_44_128", "LC_128_44100_stereo")),
            "get_license": AsyncMock(
                return_value={
                    "content_license": {
                        "content_metadata": {
                            "content_reference": {
                                "codec": "mp4a.40.2",
                                "content_size_in_bytes": 57600000,
                            },
                            "chapter_info": {"runtime_length_ms": 3600000},
                            "content_url": {
                                "offline_url": "https://fixture-media.invalid/secret"
                            },
                        },
                        "license_response": {"key": "fixture-license-key"},
                    },
                }
            ),
            **values,
        }
    )


class TitleReportTests(unittest.IsolatedAsyncioTestCase):
    async def test_formats_are_reported_without_media_or_broker_calls(self):
        item = fake_item()
        with (
            patch("widevine_download.WidevineLicenseClient") as widevine,
            patch("audible_helper.stream_file", new_callable=AsyncMock) as stream,
        ):
            result = await audio_offers(
                item, None, "best", False, 5, check_license_response, failure_code
            )
        item.get_license.assert_awaited_once_with(
            "best", "content_reference,chapter_info"
        )
        widevine.assert_not_called()
        stream.assert_not_awaited()
        self.assertEqual(
            result,
            {
                "asin": ASIN,
                "offers": [
                    {
                        "format": "aax",
                        "status": "available",
                        "codec": "LC_128_44100_stereo",
                        "bitrateKbps": 128,
                        "channels": 2,
                    },
                    {
                        "format": "aaxc",
                        "status": "available",
                        "codec": "mp4a.40.2",
                        "bitrateKbps": 128,
                        "bitrateEstimated": True,
                    },
                    {
                        "format": "widevine",
                        "status": "notChecked",
                        "reason": "widevineDisabled",
                    },
                ],
            },
        )
        self.assertNotIn("fixture-license-key", json.dumps(result))
        self.assertNotIn("fixture-media.invalid", json.dumps(result))

    async def test_widevine_offer_uses_first_party_license_probe_only(self):
        item = fake_item(is_ayce=True)
        calls = []

        def respond(request):
            calls.append(str(request.url))
            self.assertEqual(
                str(request.url),
                f"https://api.audible.co.uk/1.0/content/{ASIN}/licenserequest",
            )
            return httpx.Response(
                200,
                json={
                    "content_license": {
                        "status_code": "Granted",
                        "drm_type": "Widevine",
                        "content_metadata": {
                            "content_reference": {"codec": "mp4a.40.42"}
                        },
                        "license_response": "https://fixture-manifest.invalid/opaque-token",
                    },
                },
            )

        auth = fake_auth(ANDROID_DEVICE_TYPE)
        auth.sign_request = Mock()
        auth.refresh_token = "Atnr|fixture"
        with (
            patch(
                "widevine_download.httpx.AsyncClient",
                side_effect=transport_for(respond),
            ),
            patch("widevine_download.Cdm") as cdm,
        ):
            result = await audio_offers(
                item, auth, "best", True, 5, check_license_response, failure_code
            )
        self.assertEqual(len(calls), 1)
        cdm.assert_not_called()
        self.assertEqual(result["offers"][0]["status"], "notOffered")
        self.assertEqual(
            result["offers"][2],
            {
                "format": "widevine",
                "status": "available",
                "codec": "mp4a.40.42",
            },
        )
        self.assertNotIn("fixture-manifest", json.dumps(result))

    async def test_offline_restriction_and_unreleased_skip_checks(self):
        for options, reason in (
            (
                {"customer_rights": {"is_consumable_offline": False}},
                "offlineRestricted",
            ),
            ({"is_published": Mock(return_value=False)}, "notPublished"),
            ({"is_parent_podcast": Mock(return_value=True)}, "podcastSeries"),
        ):
            with self.subTest(reason=reason):
                item = fake_item(**options)
                result = await audio_offers(
                    item, None, "best", True, 5, check_license_response, failure_code
                )
                self.assertTrue(
                    all(
                        row["status"] == "notChecked" and row["reason"] == reason
                        for row in result["offers"]
                    )
                )
                item.get_license.assert_not_awaited()

    async def test_throttled_widevine_skips_additional_license_request(self):
        item = fake_item()
        with patch("widevine_download.WidevineLicenseClient") as probe:
            probe.return_value.license = AsyncMock(
                side_effect=OperationError("licenseThrottled")
            )
            result = await audio_offers(
                item, None, "best", True, 5, check_license_response, failure_code
            )
        item.get_license.assert_not_awaited()
        self.assertEqual(result["offers"][1]["status"], "notChecked")
        self.assertEqual(result["offers"][2]["reason"], "licenseThrottled")
        self.assertEqual(result["offers"][2]["status"], "denied")

    async def test_aaxc_no_offer_is_distinct_from_license_denial(self):
        for reason, expected in (
            ("aaxcUnavailable", "notOffered"),
            ("licenseEntitlement", "denied"),
        ):
            with self.subTest(reason=reason):
                item = fake_item(
                    get_license=AsyncMock(side_effect=OperationError(reason))
                )
                result = await audio_offers(
                    item, None, "best", False, 5, check_license_response, failure_code
                )
                self.assertEqual(
                    result["offers"][1],
                    {"format": "aaxc", "status": expected, "reason": reason},
                )

    async def test_advertised_aax_without_offline_access_remains_unconfirmed(self):
        item = fake_item(customer_rights={})
        result = await audio_offers(
            item, None, "best", False, 5, check_license_response, failure_code
        )
        self.assertEqual(result["offers"][0]["status"], "notChecked")
        self.assertEqual(result["offers"][0]["reason"], "licenseEntitlement")
        self.assertEqual(result["offers"][0]["bitrateKbps"], 128)
        self.assertEqual(result["offers"][1]["status"], "available")

    async def test_wire_command_routes_to_rights_checks(self):
        item = fake_item()
        with patch(
            "audible_helper.library_item", new_callable=AsyncMock, return_value=item
        ) as request:
            result = await execute(
                {
                    "command": "checkTitle",
                    "session": '{"locale_code":"uk"}',
                    "asin": ASIN,
                    "options": {"quality": "high"},
                }
            )
        self.assertEqual(request.call_args.args[1], ASIN)
        item.get_license.assert_awaited_once_with(
            "high", "content_reference,chapter_info"
        )
        self.assertEqual(result["asin"], ASIN)

    async def test_wire_preferred_aax_only_avoids_license_requests(self):
        for mode, widevine_enabled in (("aaxOnly", True), ("preferAAX", False)):
            with self.subTest(mode=mode):
                item = fake_item()
                with (
                    patch("audible_helper.library_item", new=AsyncMock(return_value=item)),
                    patch("widevine_download.WidevineLicenseClient") as widevine,
                ):
                    result = await execute(
                        {
                            "command": "checkTitle",
                            "session": '{"locale_code":"uk"}',
                            "asin": ASIN,
                            "preferredAudioOnly": True,
                            "options": {"format": mode, "preferWidevine": widevine_enabled},
                        }
                    )
                self.assertEqual(
                    [(row["format"], row["status"]) for row in result["offers"]],
                    [("aax", "available")],
                )
                item.get_license.assert_not_awaited()
                widevine.assert_not_called()

    async def test_wire_preferred_flag_only_accepts_literal_true(self):
        item = fake_item()
        with patch("audible_helper.library_item", new=AsyncMock(return_value=item)):
            result = await execute(
                {
                    "command": "checkTitle",
                    "session": '{"locale_code":"uk"}',
                    "asin": ASIN,
                    "preferredAudioOnly": "true",
                    "options": {"format": "aaxOnly"},
                }
            )
        self.assertEqual(len(result["offers"]), 3)
        item.get_license.assert_awaited_once()

    async def test_preferred_aaxc_only_skips_other_formats(self):
        item = fake_item()
        with patch("widevine_download.WidevineLicenseClient") as widevine:
            result = await audio_offers(
                item, None, "best", True, 5, check_license_response, failure_code,
                preferred_format="aaxcOnly",
            )
        self.assertEqual([row["format"] for row in result["offers"]], ["aaxc"])
        self.assertEqual(result["offers"][0]["status"], "available")
        item.get_license.assert_awaited_once()
        item._get_codec.assert_not_called()
        widevine.assert_not_called()

    async def test_preferred_widevine_only_falls_back_for_unsupported_offer(self):
        for outcome, status, other_formats in (
            (None, "available", []),
            (WidevineUnavailable(), "notOffered", ["aax", "aaxc"]),
            (OperationError("licenseDenied"), "denied", []),
            (OperationError("network"), "error", []),
            (OperationError("notFound"), "notOffered", []),
        ):
            with self.subTest(outcome=outcome):
                item = fake_item(is_ayce=True)
                with patch("widevine_download.WidevineLicenseClient") as widevine:
                    widevine.return_value.license = AsyncMock(
                        side_effect=outcome,
                        return_value={"content_metadata": {"content_reference": {}}},
                    )
                    result = await audio_offers(
                        item, None, "best", True, 5, check_license_response, failure_code,
                        preferred_format="preferAAX",
                    )
                offers = result["offers"]
                self.assertEqual([row["format"] for row in offers], ["widevine", *other_formats])
                self.assertEqual(offers[0]["status"], status)
                self.assertEqual(item.get_license.await_count, int("aaxc" in other_formats))

    async def test_preferred_aaxc_does_not_request_license_without_offline_rights(self):
        item = fake_item(customer_rights={})
        result = await audio_offers(
            item, None, "best", False, 5, check_license_response, failure_code,
            preferred_format="aaxcOnly",
        )
        self.assertEqual(result["offers"], [
            {"format": "aaxc", "status": "notChecked", "reason": "licenseEntitlement"},
        ])
        item.get_license.assert_not_awaited()


def transport_for(respond):
    original = httpx.AsyncClient
    return lambda **kwargs: original(transport=httpx.MockTransport(respond), **kwargs)


def fake_auth(device_type=ANDROID_DEVICE_TYPE):
    return SimpleNamespace(
        locale=SimpleNamespace(country_code="uk", domain="co.uk"),
        device_info={
            "device_type": device_type,
            "device_name": "Fixture Audible device",
            "device_serial_number": "fixtureSerial1234",
        },
        access_token="Atna|fixture",
        expires=9_999_999_999,
        access_token_expired=False,
        adp_token="fixture-adp",
        device_private_key="fixture-private",
        with_username=False,
    )


class RegistrationReportTests(unittest.IsolatedAsyncioTestCase):
    def test_device_report_exposes_only_safe_metadata(self):
        auth = fake_auth()
        self.assertEqual(
            device_registration(auth),
            {
                "kind": "android",
                "marketplace": "uk",
                "name": "Fixture Audible device",
                "serialSuffix": "1234",
            },
        )
        self.assertEqual(
            device_registration(fake_auth("A2CZJZGLK2JJVM"))["kind"], "iphone"
        )
        auth.device_info = {"device_serial_number": "3"}
        self.assertEqual(
            device_registration(auth), {"kind": "unknown", "marketplace": "uk"}
        )

    async def test_deregister_requires_confirmation_and_targets_only_current_device(
        self,
    ):
        auth = fake_auth()
        with patch("audible_reports.httpx.AsyncClient") as web:
            for value in (None, False, 1, "true"):
                with (
                    self.subTest(value=value),
                    self.assertRaises(OperationError) as caught,
                ):
                    await deregister_device(auth, value, 5)
                self.assertEqual(
                    caught.exception.code, "deviceDeregistrationConfirmation"
                )
        web.assert_not_called()

        def respond(request):
            self.assertEqual(
                str(request.url), "https://api.amazon.co.uk/auth/deregister"
            )
            self.assertEqual(request.headers["x-amz-access-token"], "Atna|fixture")
            self.assertEqual(
                json.loads(request.content), {"deregister_all_existing_accounts": False}
            )
            return httpx.Response(200, json={"response": {"success": {}}})

        with patch(
            "audible_reports.httpx.AsyncClient", side_effect=transport_for(respond)
        ):
            self.assertIs(await deregister_device(auth, True, 5), True)

    async def test_deregister_rejects_unsuccessful_body(self):
        for body in (
            {"response": {"error": {"message": "secret fixture"}}},
            {"response": {"success": False}},
            {"success": False},
            {"success": False, "response": {"success": {}}},
        ):
            def respond(_request):
                return httpx.Response(200, json=body)

            with (
                self.subTest(body=body),
                patch("audible_reports.httpx.AsyncClient", side_effect=transport_for(respond)),
                self.assertRaises(OperationError) as caught,
            ):
                await deregister_device(fake_auth(), True, 5)
            self.assertEqual(caught.exception.code, "deviceDeregistration")

    async def test_wire_deregister_bounds_request_timeout(self):
        for requested, expected in ((0, 45), (600, 45), (15, 15)):
            with (
                self.subTest(requested=requested),
                patch("audible_reports.deregister_device", new=AsyncMock(return_value=True)) as perform,
            ):
                result = await execute(
                    {"command": "deregisterDevice", "session": '{"locale_code":"uk"}',
                     "confirmed": True, "options": {"timeout": requested}}
                )
                self.assertIs(result, True)
                self.assertEqual(perform.await_args.args[1:], (True, expected))
        self.assertEqual(failure_code(TimeoutError()), "timeout")


class ListeningStatsTests(unittest.IsolatedAsyncioTestCase):
    async def test_reports_full_monthly_duration_and_no_future_months(self):
        client = SimpleNamespace(
            get=AsyncMock(
                side_effect=[
                    {
                        "aggregated_monthly_listening_stats": [
                            {
                                "interval_identifier": "2025-03",
                                "aggregated_sum": "2.01e8",
                            },
                            {"interval_identifier": "2025-02", "aggregated_sum": 0},
                        ]
                    },
                    {
                        "aggregated_monthly_listening_stats": [
                            {
                                "interval_identifier": "2026-04",
                                "aggregated_sum": 3600123.0,
                            },
                        ]
                    },
                ]
            )
        )
        with patch("audible_reports.datetime") as date:
            date.now.return_value = datetime(2026, 5, 15)
            result = await listening_stats(client, 2025)
        self.assertEqual(
            result["months"],
            [
                {"month": "2025-02", "durationMilliseconds": 0},
                {"month": "2025-03", "durationMilliseconds": 201000000},
                {"month": "2026-04", "durationMilliseconds": 3600123},
            ],
        )
        requests = client.get.await_args_list
        self.assertEqual(
            [request.args[0] for request in requests],
            ["stats/aggregates", "stats/aggregates"],
        )
        self.assertEqual(
            [
                request.kwargs["monthly_listening_interval_duration"]
                for request in requests
            ],
            ["12", "5"],
        )
        self.assertTrue(
            all(request.kwargs["store"] == "Audible" for request in requests)
        )

    async def test_rejects_malformed_date_range_before_request(self):
        client = SimpleNamespace(get=AsyncMock())
        for year in (True, None, 1996, "2025", 2040):
            with self.subTest(year=year), self.assertRaises(OperationError) as caught:
                await listening_stats(client, year)
            self.assertEqual(caught.exception.code, "listeningStatsYear")
        client.get.assert_not_awaited()

    async def test_rejects_inconsistent_monthly_response(self):
        client = SimpleNamespace(
            get=AsyncMock(
                return_value={
                    "aggregated_monthly_listening_stats": [
                        {"interval_identifier": "2026-01", "aggregated_sum": 100},
                        {"interval_identifier": "2026-01", "aggregated_sum": 200},
                    ],
                }
            )
        )
        with (
            patch("audible_reports.datetime") as date,
            self.assertRaises(OperationError) as caught,
        ):
            date.now.return_value = datetime(2026, 6, 1)
            await listening_stats(client, 2026)
        self.assertEqual(caught.exception.code, "listeningStatsResponse")

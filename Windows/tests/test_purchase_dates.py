"""Check Windows purchase-date storage and local request boundaries."""

from datetime import datetime, timezone
from unittest import TestCase

from downaudible_windows.purchase_dates import purchase_date_options, purchase_date_text


class PurchaseDateTests(TestCase):
    def test_legacy_utc_endpoints_keep_the_selected_dates_and_use_local_bounds(self):
        legacy_start = datetime(2026, 3, 8, tzinfo=timezone.utc).timestamp()
        legacy_end = datetime(2026, 3, 8, 23, 59, 59, 999999, tzinfo=timezone.utc).timestamp()
        options = {
            "purchaseStart": legacy_start,
            "purchaseEnd": legacy_end,
            "pageSize": 50,
        }
        self.assertEqual(purchase_date_text(legacy_start), "2026-03-08")
        self.assertEqual(purchase_date_text(legacy_end), "2026-03-08")
        self.assertEqual(
            purchase_date_options(options),
            {
                "purchaseStart": datetime(2026, 3, 8).timestamp(),
                "purchaseEnd": datetime(2026, 3, 9).timestamp() - 0.000001,
                "pageSize": 50,
            },
        )
        self.assertEqual(options["purchaseStart"], legacy_start)

    def test_rejects_reversed_ranges_and_invalid_dates(self):
        with self.assertRaisesRegex(ValueError, "end date on or after the start date"):
            purchase_date_options({"purchaseStart": "2026-11-22", "purchaseEnd": "2026-11-21"})
        with self.assertRaisesRegex(ValueError, "YYYY-MM-DD"):
            purchase_date_options({"purchaseStart": "2026-02-29"})

    def test_blank_field_leaves_that_boundary_open(self):
        self.assertEqual(
            purchase_date_options({"purchaseStart": " ", "purchaseEnd": "2026-11-21"}),
            {"purchaseEnd": datetime(2026, 11, 22).timestamp() - 0.000001},
        )

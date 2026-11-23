import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch

from downaudible_windows import release


class ReleaseMetadataTests(TestCase):
    def test_reads_the_shared_xcode_values(self):
        with TemporaryDirectory() as directory:
            config = Path(directory) / "App.xcconfig"
            config.write_text(
                "// Release metadata\nCURRENT_PROJECT_VERSION = 19\n"
                "MARKETING_VERSION = 1.2.3 // Public version\n",
                encoding="utf-8",
            )
            self.assertEqual(release.read_xcconfig(config).file_version, "1.2.3.19")

    def test_rejects_ambiguous_or_out_of_range_shared_values(self):
        for version, build in (
            ("1.2.3\nMARKETING_VERSION = 2.0.0", "1"),
            ("01.2.3", "1"),
            ("1.2.65536", "1"),
            ("1.2.3", "65536"),
            ("1.2.3", "0"),
        ):
            with (
                self.subTest(version=version, build=build),
                TemporaryDirectory() as directory,
            ):
                config = Path(directory) / "App.xcconfig"
                config.write_text(
                    f"MARKETING_VERSION = {version}\nCURRENT_PROJECT_VERSION = {build}\n",
                    encoding="utf-8",
                )
                with self.assertRaises(ValueError):
                    release.read_xcconfig(config)

    def test_installed_app_reads_metadata_without_a_checkout(self):
        with TemporaryDirectory() as directory:
            module = Path(directory) / "release.py"
            module.with_suffix(".json").write_text(
                json.dumps({"version": "2.0.1", "build": 20}), encoding="utf-8"
            )
            with patch.object(release, "__file__", str(module)):
                self.assertEqual(
                    release.installed_release(), release.Release("2.0.1", 20)
                )

import io
import json
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path
from unittest.mock import patch

from downaudible_windows import updater

PAYLOAD = b"synthetic installer data"
PUBLISHER = "CN=Example Publisher, O=Example Organisation"


def release(version, architecture="arm64", *, legacy=False, payload=PAYLOAD, **changes):
    filename = (
        f"DownAudible-{version}-windows-{architecture}-Setup.exe"
        if legacy
        else updater.windows_asset_name(architecture, "installer")
    )
    return {
        "tag_name": f"V{version}",
        "draft": False,
        "prerelease": False,
        "assets": [
            {
                "name": filename,
                "browser_download_url": f"{updater.PROJECT}/releases/download/V{version}/{filename}",
                "size": len(payload),
                "state": "uploaded",
                "digest": f"sha256:{sha256(payload).hexdigest()}",
            }
        ],
    } | changes


def update_for(item, architecture="arm64"):
    return updater.windows_asset(item, architecture)[1]


class UpdateTests(unittest.TestCase):
    def test_selects_highest_matching_stable_release(self):
        releases = [
            release("0.12.0", prerelease=True),
            release("0.11.0", "x64"),
            release("0.9.0"),
            release("0.10.0"),
            release("0.1.0"),
        ]
        with patch.object(
            updater,
            "open_release",
            return_value=io.BytesIO(json.dumps(releases).encode()),
        ):
            update = updater.check_update("0.8.0", "arm64")
        self.assertEqual(update.version, "0.10.0")
        self.assertEqual(update.filename, "DownAudible-Windows-ARM64-Installer.exe")
        self.assertEqual(
            update.download_url,
            f"{updater.PROJECT}/releases/download/V0.10.0/DownAudible-Windows-ARM64-Installer.exe",
        )

    def test_prefers_canonical_installer_over_legacy_asset_in_the_same_release(self):
        item = release("0.10.0", "x64", legacy=True)
        item["assets"] += release("0.10.0", "x64")["assets"]
        update = update_for(item, "x64")
        self.assertEqual(update.filename, "DownAudible-Windows-x64-Installer.exe")

    def test_rejects_a_latest_download_alias_in_release_metadata(self):
        item = release("0.10.0")
        item["assets"][0]["browser_download_url"] = (
            f"{updater.PROJECT}/releases/latest/download/{item['assets'][0]['name']}"
        )
        self.assertIsNone(updater.windows_asset(item, "arm64"))

    def test_ignores_assets_hosted_outside_official_release(self):
        item = release("0.10.0")
        item["assets"][0]["browser_download_url"] = (
            "https://example.com/Windows-Setup.exe"
        )
        with patch.object(
            updater,
            "open_release",
            return_value=io.BytesIO(json.dumps([item]).encode()),
        ):
            self.assertIsNone(updater.check_update("0.9.0", "arm64"))

    def test_requires_size_digest_and_publisher(self):
        update = update_for(release("0.10.0", legacy=True))
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(updater, "open_release", return_value=io.BytesIO(PAYLOAD)),
            patch.object(updater, "authenticode_subject", return_value=PUBLISHER),
        ):
            installer = updater.download_verified(
                update, Path(directory), expected_publisher=PUBLISHER
            )
            self.assertEqual(installer.read_bytes(), PAYLOAD)
            self.assertEqual(installer.name, "DownAudible-0.10.0-windows-arm64-Setup.exe")

    def test_stages_new_releases_with_the_same_installer_name_separately(self):
        new_payload = b"new synthetic installer data"
        previous = update_for(release("0.10.0"))
        latest = update_for(release("0.11.0", payload=new_payload))
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(
                updater,
                "open_release",
                side_effect=[io.BytesIO(PAYLOAD), io.BytesIO(new_payload)],
            ),
            patch.object(updater, "authenticode_subject", return_value=PUBLISHER),
        ):
            first = updater.download_verified(previous, Path(directory), expected_publisher=PUBLISHER)
            second = updater.download_verified(latest, Path(directory), expected_publisher=PUBLISHER)
            self.assertEqual(first.name, second.name)
            self.assertNotEqual(first.parent, second.parent)
            self.assertEqual(first.read_bytes(), PAYLOAD)
            self.assertEqual(second.read_bytes(), new_payload)

    def test_rejects_checksum_mismatch_before_checking_signature(self):
        update = update_for(release("0.10.0"))
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(
                updater, "open_release", return_value=io.BytesIO(b"x" * len(PAYLOAD))
            ),
            patch.object(updater, "authenticode_subject") as signature,
        ):
            with self.assertRaisesRegex(updater.UpdateError, "checksum"):
                updater.download_verified(
                    update, Path(directory), expected_publisher=PUBLISHER
                )
            signature.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_requires_correct_signer_when_api_has_no_digest(self):
        item = release("0.10.0")
        item["assets"][0]["digest"] = None
        update = update_for(item)
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(updater, "open_release", return_value=io.BytesIO(PAYLOAD)),
            patch.object(
                updater, "authenticode_subject", return_value="CN=Someone Else"
            ),
        ):
            with self.assertRaisesRegex(updater.UpdateError, "unexpected publisher"):
                updater.download_verified(
                    update, Path(directory), expected_publisher=PUBLISHER
                )
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_requires_configured_publisher_before_network_request(self):
        update = update_for(release("0.10.0"))
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(updater, "open_release") as network,
            self.assertRaisesRegex(updater.UpdateError, "publisher"),
        ):
            updater.download_verified(update, Path(directory), expected_publisher="")
        network.assert_not_called()

    def test_rejects_truncated_download_before_checking_signature(self):
        update = update_for(release("0.10.0"))
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(
                updater, "open_release", return_value=io.BytesIO(PAYLOAD[:-1])
            ),
            patch.object(updater, "authenticode_subject") as signature,
        ):
            with self.assertRaisesRegex(updater.UpdateError, "incomplete"):
                updater.download_verified(
                    update, Path(directory), expected_publisher=PUBLISHER
                )
            signature.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_detects_the_running_binary_instead_of_the_host_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "python.exe"
            header = bytearray(70)
            header[:2] = b"MZ"
            header[0x3C:0x40] = (64).to_bytes(4, "little")
            header[64:68] = b"PE\x00\x00"
            with patch.dict(updater.os.environ, {"PROCESSOR_ARCHITECTURE": "ARM64"}):
                for machine, target in ((0x8664, "x64"), (0xAA64, "arm64")):
                    header[68:70] = machine.to_bytes(2, "little")
                    executable.write_bytes(header)
                    self.assertEqual(
                        updater.running_windows_architecture(executable), target
                    )
                executable.write_bytes(b"not an executable")
                with self.assertRaisesRegex(updater.UpdateError, "architecture"):
                    updater.running_windows_architecture(executable)

    def test_skips_missing_and_malformed_release_metadata(self):
        older = release("0.10.0")
        older["assets"].insert(0, None)
        releases = [None, release("0.11.0", assets=None), older]
        with patch.object(
            updater,
            "open_release",
            return_value=io.BytesIO(json.dumps(releases).encode()),
        ):
            self.assertEqual(updater.check_update("0.9.0", "arm64").version, "0.10.0")

    def test_handoff_keeps_the_installed_path_and_verifies_the_same_bytes_again(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(updater, "authenticode_subject", return_value=PUBLISHER),
            patch.object(
                updater, "windows_powershell", return_value=[str(Path(directory) / "System" / "powershell.exe")]
            ),
            patch.object(updater.subprocess, "CREATE_NO_WINDOW", 0, create=True),
            patch.object(updater.subprocess, "Popen") as child,
        ):
            installed = Path(directory) / "Alt Install"
            installed.mkdir()
            (installed / "Uninstall.exe").touch()
            installer = Path(directory) / "Setup.exe"
            installer.write_bytes(PAYLOAD)
            updater.schedule_verified_install(
                installer, installed, expected_publisher=PUBLISHER, launcher_pid=42, restart=True
            )
            script = child.call_args.args[0][-1]
            environment = child.call_args.kwargs["env"]
            self.assertEqual(child.call_args.kwargs["cwd"], Path(directory) / "System")
            self.assertEqual(
                environment["DOWNAUDIBLE_INSTALL_DIRECTORY"], str(installed.resolve())
            )
            self.assertEqual(
                environment["DOWNAUDIBLE_UPDATE_SHA256"], sha256(PAYLOAD).hexdigest()
            )
            self.assertEqual(environment["DOWNAUDIBLE_LAUNCHER_PID"], "42")
            self.assertEqual(environment["DOWNAUDIBLE_RESTART_AFTER_INSTALL"], "1")
            self.assertLess(
                script.index("WaitForExit"), script.index("[System.IO.File]::Open")
            )
            self.assertLess(
                script.index("Get-AuthenticodeSignature"), script.index("Start-Process")
            )
            self.assertLess(script.index("Get-FileHash"), script.index("Start-Process"))
            self.assertLess(script.index("if ($setup.ExitCode -ne 0)"), script.index("Start-Process -FilePath $launcher"))

    def test_handoff_refuses_to_lock_an_installer_inside_the_app_folder(self):
        with tempfile.TemporaryDirectory() as directory:
            install = Path(directory)
            (install / "Uninstall.exe").touch()
            with self.assertRaisesRegex(updater.UpdateError, "staged outside"):
                updater.schedule_verified_install(
                    install / "Setup.exe", install, expected_publisher=PUBLISHER, launcher_pid=42
                )

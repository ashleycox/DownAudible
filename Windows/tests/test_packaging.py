import json
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile


@unittest.skipUnless(
    sys.platform in {"darwin", "linux"}, "Requires a macOS or Linux build host"
)
class PackagingTests(unittest.TestCase):
    def test_build_uses_stable_asset_names_with_versioned_portable_content(self):
        import build_windows
        from downaudible_windows.release import Release

        def make_runtime(_cache, root, _architecture):
            runtime = root / "python"
            runtime.mkdir()
            return runtime

        def make_installer(*arguments, **_options):
            (output,) = (
                arg
                for arg in arguments
                if isinstance(arg, str) and arg.startswith("-DOUTPUT=")
            )
            Path(output.removeprefix("-DOUTPUT=")).write_bytes(b"installer fixture")

        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            source = workspace / "downaudible_windows"
            source.mkdir()
            (source / "__main__.py").touch()
            output = workspace / "dist"
            with (
                patch.object(build_windows, "WINDOWS", workspace),
                patch.object(build_windows, "bundle_python", side_effect=make_runtime),
                patch.object(build_windows, "app_resources"),
                patch.object(
                    build_windows, "windows_icon", return_value=Path("DownAudible.ico")
                ),
                patch.object(build_windows, "bundle_launcher"),
                patch.object(
                    build_windows, "installer_compiler", return_value=("makensis", {})
                ),
                patch.object(build_windows, "run", side_effect=make_installer),
                patch.object(build_windows, "verify_pe"),
            ):
                for version, build in (("3.4.5", 12), ("3.4.6", 13)):
                    for architecture in ("arm64", "x64"):
                        build_windows.build(
                            workspace,
                            output,
                            architecture,
                            "both",
                            None,
                            None,
                            Release(version, build),
                            "",
                            None,
                        )
            expected = {
                "DownAudible-Windows-ARM64-Installer.exe",
                "DownAudible-Windows-ARM64-Portable.zip",
                "DownAudible-Windows-x64-Installer.exe",
                "DownAudible-Windows-x64-Portable.zip",
            }
            self.assertEqual(
                {
                    asset.name
                    for asset in output.iterdir()
                    if not asset.name.startswith(".")
                },
                expected,
            )
            for label in ("ARM64", "x64"):
                with ZipFile(
                    output / f"DownAudible-Windows-{label}-Portable.zip"
                ) as archive:
                    metadata = archive.read(
                        f"DownAudible-3.4.6-windows-{label.lower()}/python/downaudible_windows/release.json"
                    )
                    self.assertEqual(
                        json.loads(metadata), {"version": "3.4.6", "build": 13}
                    )

    def test_signing_hook_rejects_a_signer_that_leaves_no_certificate(self):
        from build_windows import sign_executable

        with tempfile.TemporaryDirectory() as directory:
            launcher = Path(directory) / "DownAudible.exe"
            binary = bytearray(512)
            binary[:2] = b"MZ"
            struct.pack_into("<I", binary, 0x3C, 128)
            binary[128:132] = b"PE\0\0"
            struct.pack_into("<H", binary, 152, 0x20B)
            launcher.write_bytes(binary)
            with self.assertRaisesRegex(
                ValueError, "did not embed an Authenticode signature"
            ):
                sign_executable(launcher, "/usr/bin/true")

    def test_portable_archive_ignores_staging_path_and_timestamps(self):
        from build_windows import SOURCE_DATE_EPOCH, write_portable_zip

        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            archives = []
            for index, filenames in enumerate((("a.txt", "b.txt"), ("b.txt", "a.txt"))):
                staging = workspace / str(index) / "DownAudible"
                staging.mkdir(parents=True)
                for filename in filenames:
                    source = staging / filename
                    source.write_text(filename, encoding="ascii")
                    mtime = SOURCE_DATE_EPOCH + index * 10000
                    os.utime(source, (mtime, mtime))
                archive = staging.with_suffix(".zip")
                write_portable_zip(staging, archive, SOURCE_DATE_EPOCH)
                archives.append(archive.read_bytes())
            self.assertEqual(*archives)

    def test_packaging_removes_host_wrappers_and_their_record_entries(self):
        from build_windows import remove_host_scripts

        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            cli = runtime / "bin" / "example"
            cli.parent.mkdir()
            cli.write_text("#!/private/host/python3", encoding="ascii")
            record = runtime / "example.dist-info" / "RECORD"
            record.parent.mkdir()
            record.write_text(
                "bin/example,sha256:host,23\nmodule.py,sha256:app,42\n",
                encoding="ascii",
            )
            remove_host_scripts(runtime)
            self.assertFalse(cli.exists())
            self.assertEqual(
                record.read_text(encoding="ascii"), "module.py,sha256:app,42\n"
            )

    def test_publication_copies_all_outputs_before_replacing_existing_artifacts(self):
        from build_windows import publish_artifacts

        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            output = workspace / "dist"
            output.mkdir()
            artifacts = [
                workspace / filename for filename in ("Setup.exe", "Portable.zip")
            ]
            for artifact in artifacts:
                artifact.write_bytes(b"new")
                (output / artifact.name).write_bytes(b"original")
            with (
                patch(
                    "build_windows.shutil.copyfile",
                    side_effect=[None, OSError("copy failed")],
                ),
                self.assertRaisesRegex(OSError, "copy failed"),
            ):
                publish_artifacts(artifacts, output, "DownAudible")
            for artifact in artifacts:
                self.assertEqual((output / artifact.name).read_bytes(), b"original")

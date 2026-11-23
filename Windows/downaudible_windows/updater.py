"""Find official stable Windows releases and stage verified installers."""

import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from hashlib import file_digest, sha256
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .release import windows_asset_name

PROJECT = "https://github.com/ashleycox/DownAudible"
RELEASES = "https://api.github.com/repos/ashleycox/DownAudible/releases?per_page=50"
DOWNLOAD_HOSTS = {
    "github.com",
    "release-assets.githubusercontent.com",
    "objects.githubusercontent.com",
}
HEADERS = {"Accept": "application/vnd.github+json", "User-Agent": "DownAudible-Windows"}
VERSION_TAG = re.compile(r"[vV]?([0-9]+\.[0-9]+\.[0-9]+)")
SHA256_DIGEST = re.compile(r"sha256:[a-fA-F0-9]{64}")
MAX_INSTALLER_SIZE = 1024 * 1024 * 1024
PE_MACHINES = {0x8664: "x64", 0xAA64: "arm64"}
AUTHENTICODE_CHECK = r"""
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1')
$signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $installer
if ($signature.Status -ne 'Valid' -or $signature.SignatureType -ne 'Authenticode' -or !$signature.SignerCertificate) { exit 1 }
"""


class UpdateError(Exception):
    """The Windows installer could not be located or verified."""


@dataclass(frozen=True, slots=True)
class Update:
    version: str
    architecture: str
    release_url: str
    download_url: str
    filename: str
    size: int
    digest: str | None


class ReleaseRedirects(HTTPRedirectHandler):
    def __init__(self, hosts):
        self.hosts = hosts

    def redirect_request(self, request, response, code, message, headers, new_url):
        parsed = urlsplit(new_url)
        if parsed.scheme != "https" or parsed.netloc not in self.hosts:
            raise UpdateError("The update redirected outside GitHub.")
        return super().redirect_request(
            request, response, code, message, headers, new_url
        )


def open_release(url, hosts, *, timeout=20):
    request = Request(url, headers=HEADERS)
    return build_opener(ReleaseRedirects(hosts)).open(request, timeout=timeout)


def release_version(value):
    match = VERSION_TAG.fullmatch(str(value))
    if match is None:
        return None
    version = match.group(1)
    return tuple(map(int, version.split("."))), version


def running_windows_architecture(executable: Path | None = None) -> str:
    """Read the runtime's PE header so x64 on ARM Windows stays on the x64 channel."""
    executable = Path(executable or sys.executable)
    try:
        with executable.open("rb") as stream:
            if stream.read(2) != b"MZ":
                raise ValueError("Missing Windows executable signature")
            stream.seek(0x3C)
            offset = int.from_bytes(stream.read(4), "little")
            stream.seek(offset)
            if stream.read(4) != b"PE\0\0":
                raise ValueError("Missing Windows PE header")
            return PE_MACHINES[int.from_bytes(stream.read(2), "little")]
    except (OSError, ValueError, KeyError) as error:
        raise UpdateError("The installed Windows architecture is unknown.") from error


def windows_asset(release, architecture):
    if not isinstance(release, dict) or architecture not in ("x64", "arm64"):
        return None
    tag = release.get("tag_name")
    parsed_version = release_version(tag)
    if parsed_version is None or release.get("draft") or release.get("prerelease"):
        return None
    numbers, version = parsed_version
    release_url = f"{PROJECT}/releases/tag/{tag}"
    assets = release.get("assets", [])
    if not isinstance(assets, list):
        return None
    filenames = (
        windows_asset_name(architecture, "installer"),
        f"DownAudible-{version}-windows-{architecture}-Setup.exe",
    )
    for filename in filenames:
        download_url = f"{PROJECT}/releases/download/{tag}/{filename}"
        for asset in assets:
            if (
                not isinstance(asset, dict)
                or asset.get("name") != filename
                or asset.get("browser_download_url") != download_url
            ):
                continue
            size = asset.get("size")
            digest = asset.get("digest")
            if (
                asset.get("state") != "uploaded"
                or type(size) is not int
                or not 0 < size <= MAX_INSTALLER_SIZE
            ):
                continue
            if digest is not None and (
                not isinstance(digest, str) or SHA256_DIGEST.fullmatch(digest) is None
            ):
                continue
            return numbers, Update(
                version, architecture, release_url, download_url, filename, size, digest
            )
    return None


def check_update(current: str, arch: str) -> Update | None:
    version = release_version(current)
    if version is None or arch not in {"x64", "arm64"}:
        raise UpdateError("The installed version or Windows architecture is unknown.")
    try:
        with open_release(RELEASES, {"api.github.com"}) as response:
            releases = json.load(response)
        if not isinstance(releases, list):
            raise TypeError("Expected a GitHub release list.")
        candidates = (windows_asset(release, arch) for release in releases)
        available = (
            candidate
            for candidate in candidates
            if candidate and candidate[0] > version[0]
        )
        latest = max(available, key=lambda candidate: candidate[0], default=None)
        return latest[1] if latest else None
    except (OSError, ValueError, AttributeError, TypeError) as error:
        raise UpdateError(
            "DownAudible could not read its Windows releases from GitHub."
        ) from error


def windows_powershell() -> list[str]:
    if os.name != "nt":
        raise UpdateError("Authenticode verification requires Windows.")
    system_directory = ctypes.create_unicode_buffer(32768)
    length = ctypes.windll.kernel32.GetSystemDirectoryW(
        system_directory, len(system_directory)
    )
    if not 0 < length < len(system_directory):
        raise UpdateError("DownAudible could not locate Windows PowerShell.")
    executable = (
        Path(system_directory.value) / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    )
    return [str(executable), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command"]


def authenticode_subject(installer: Path) -> str:
    script = (
        """
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$installer = $env:DOWNAUDIBLE_INSTALLER
"""
        + AUTHENTICODE_CHECK
        + "[Console]::WriteLine($signature.SignerCertificate.Subject)"
    )
    try:
        result = subprocess.run(
            [*windows_powershell(), script],
            env=os.environ | {"DOWNAUDIBLE_INSTALLER": str(installer.resolve())},
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=45,
            creationflags=subprocess.CREATE_NO_WINDOW,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise UpdateError(
            "DownAudible could not verify the installer’s Authenticode signature."
        ) from error
    subject = result.stdout.strip()
    if result.returncode or not subject:
        raise UpdateError(
            "The Windows installer has no trusted Authenticode signature."
        )
    return subject


def verify_publisher(installer: Path, expected_publisher: str) -> None:
    if not expected_publisher or authenticode_subject(installer) != expected_publisher:
        raise UpdateError(
            "The Windows installer was signed by an unexpected publisher."
        )


def schedule_verified_install(
    installer: Path, install_dir: Path, *, expected_publisher: str, launcher_pid: int, restart: bool = False
) -> None:
    """Wait for this app and its launcher, then update this installation with the same verified bytes."""
    if launcher_pid <= 0 or not (install_dir / "Uninstall.exe").is_file():
        raise UpdateError(
            "The Windows updater could not locate the installed app and its launcher."
        )
    installer, install_dir = installer.resolve(), install_dir.resolve()
    if installer.is_relative_to(install_dir):
        raise UpdateError("The installer must be staged outside the DownAudible installation folder.")
    publisher = expected_publisher.strip()
    verify_publisher(installer, publisher)
    try:
        with installer.open("rb") as stream:
            digest = file_digest(stream, "sha256").hexdigest()
    except OSError as error:
        raise UpdateError(
            "The downloaded Windows installer is no longer available."
        ) from error
    script = (
        """
$ErrorActionPreference = 'Stop'
$installer = $env:DOWNAUDIBLE_INSTALLER
$ids = @([int]$env:DOWNAUDIBLE_GUI_PID, [int]$env:DOWNAUDIBLE_LAUNCHER_PID)
foreach ($appProcess in @(Get-Process -Id $ids -ErrorAction SilentlyContinue)) {
    if (!$appProcess.HasExited -and !$appProcess.WaitForExit(120000)) { exit 1 }
}
$lease = [System.IO.File]::Open($installer, 'Open', 'Read', 'Read')
try {
"""
        + AUTHENTICODE_CHECK
        + """
    if ($signature.SignerCertificate.Subject -cne $env:DOWNAUDIBLE_UPDATE_PUBLISHER) { exit 1 }
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ine $env:DOWNAUDIBLE_UPDATE_SHA256) { exit 1 }
    $arguments = '/S /D=' + $env:DOWNAUDIBLE_INSTALL_DIRECTORY
    $setup = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    if ($setup.ExitCode -ne 0) { exit $setup.ExitCode }
    if ($env:DOWNAUDIBLE_RESTART_AFTER_INSTALL -eq '1') {
        $launcher = Join-Path $env:DOWNAUDIBLE_INSTALL_DIRECTORY 'DownAudible.exe'
        Start-Process -FilePath $launcher -WorkingDirectory $env:DOWNAUDIBLE_INSTALL_DIRECTORY
    }
} finally {
    $lease.Dispose()
}
"""
    )
    try:
        powershell = windows_powershell()
        subprocess.Popen(
            [*powershell, script],
            cwd=Path(powershell[0]).parent,
            env=os.environ
            | {
                "DOWNAUDIBLE_INSTALLER": str(installer),
                "DOWNAUDIBLE_INSTALL_DIRECTORY": str(install_dir),
                "DOWNAUDIBLE_UPDATE_PUBLISHER": publisher,
                "DOWNAUDIBLE_UPDATE_SHA256": digest,
                "DOWNAUDIBLE_GUI_PID": str(os.getpid()),
                "DOWNAUDIBLE_LAUNCHER_PID": str(launcher_pid),
                "DOWNAUDIBLE_RESTART_AFTER_INSTALL": "1" if restart else "0",
            },
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except OSError as error:
        raise UpdateError(
            "DownAudible could not start the verified Windows update."
        ) from error


def download_verified(
    update: Update, directory: Path, *, expected_publisher: str
) -> Path:
    """Download an installer without running it. Expected publisher is an exact trusted certificate Subject."""
    publisher = expected_publisher.strip()
    if not publisher:
        raise UpdateError(
            "A trusted publisher has not been configured for Windows updates."
        )
    release = windows_asset(
        {
            "tag_name": update.release_url.rsplit("/", 1)[-1],
            "assets": [
                {
                    "name": update.filename,
                    "browser_download_url": update.download_url,
                    "size": update.size,
                    "digest": update.digest,
                    "state": "uploaded",
                }
            ],
        },
        update.architecture,
    )
    if release is None or release[1] != update:
        raise UpdateError(
            "The installer is not an official DownAudible Windows release asset."
        )
    directory = Path(directory)
    try:
        directory.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix="WindowsUpdate-", dir=directory))
    except OSError as error:
        raise UpdateError(
            "DownAudible could not create a folder for its Windows update."
        ) from error
    installer = staging / update.filename
    verified = False
    try:
        checksum = sha256()
        received = 0
        with (
            open_release(update.download_url, DOWNLOAD_HOSTS) as response,
            installer.open("xb") as output,
        ):
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                received += len(chunk)
                if received > update.size:
                    raise UpdateError(
                        "The Windows installer size did not match GitHub’s release metadata."
                    )
                checksum.update(chunk)
                output.write(chunk)
        if received != update.size:
            raise UpdateError("The Windows installer download was incomplete.")
        if update.digest and f"sha256:{checksum.hexdigest()}" != update.digest.lower():
            raise UpdateError(
                "The Windows installer checksum did not match GitHub’s release metadata."
            )
        verify_publisher(installer, publisher)
        verified = True
        return installer
    except OSError as error:
        raise UpdateError(
            "DownAudible could not download the Windows installer."
        ) from error
    finally:
        if not verified:
            shutil.rmtree(staging, ignore_errors=True)

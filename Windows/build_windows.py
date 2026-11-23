#!/usr/bin/env python3
"""Cross-build the Windows app, portable ZIP and per-user installer."""

import argparse
import csv
import json
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
from contextlib import contextmanager
from hashlib import file_digest, sha256
from pathlib import Path
from platform import mac_ver, machine
from urllib.request import Request, urlopen

from downaudible_windows.release import read_xcconfig, windows_asset_name

WINDOWS = Path(__file__).resolve().parent
REPOSITORY = WINDOWS.parent
PACKAGING = WINDOWS / "packaging"
TOOLCHAIN_RELEASE = "20261117"
MACOS_TOOLCHAIN = (
    "macos-universal",
    "98d340bbb8d46b09ad6886ffba88bd9d5415e131c316de48e6bd7647377446aa",
)
TOOLCHAIN_HOSTS = {
    ("darwin", "arm64"): MACOS_TOOLCHAIN,
    ("darwin", "x86_64"): MACOS_TOOLCHAIN,
    ("linux", "aarch64"): (
        "ubuntu-22.04-aarch64",
        "6d9442ead9ace3b3e4c3389bfef69f93f873305e0705e6cc60978ac895320872",
    ),
    ("linux", "x86_64"): (
        "ubuntu-22.04-x86_64",
        "e7a15a49a2ea95e9f3d8a9d0cfabe5052a4b10fb4777cc54de5a8c27b64bb701",
    ),
}
PYTHON_VERSION = "3.13.18"
PYTHON_RELEASE = "20261110"
SOURCE_DATE_EPOCH = 946684800
NSIS_VERSION = "3.13"
NSIS_BOTTLES = {
    ("darwin", "arm64"): (
        "arm64-macos",
        "fb902fdc6f21f2d0dee4f78d6a1350263901624217ed2ae591b94d107e665a38",
    ),
    ("linux", "aarch64"): (
        "arm64-linux",
        "4b830b3abe54cacaa0f575d8f15d92d59316629252105f30abf59f5f38e2ded8",
    ),
    ("linux", "x86_64"): (
        "x64-linux",
        "ffa86d93e3affc4cb033d75d66c7cc4369664850928ccf518c665e6669a0ad6a",
    ),
}
SETUPTOOLS_BUILD_REQUIREMENT = "setuptools==84.2.1 --hash=sha256:ca140b45d5325a9478f880e351484f62fef15f336462e449ca0c03c873d589c2"
WX_VERSION = "4.3.2"
MARKDOWN_VERSION = "3.8.2"
MARKDOWN_SHA256 = "5c83764dbd4e00bdd94d85a19b8d55ccca20fe35b2e678a1422b380324dd5f24"
TARGETS = {
    "x64": {
        "cpu": "x86_64",
        "machine": 0x8664,
        "python": "2e0fed09d48989f64c9305da9ff2d37a41c0d13ab2aa6283405b2b620dfbf805",
        "wx": "9ef2cec75f570ac09fbcfe31cd668bbf122dc650a2c43a9016aba668c557c725",
    },
    "arm64": {
        "cpu": "aarch64",
        "machine": 0xAA64,
        "python": "0a8840071810ddb8565256cd406b466d4e9dc6dc523395a5477880dbc4f67eb3",
        "wx": "100d532ddaf457e21421f69fbcaf63d6403dc10d70ca80c1726152aaf4967856",
    },
}


def run(*command, **options):
    return subprocess.run(command, check=True, **options)


def digest(path):
    with path.open("rb") as stream:
        return file_digest(stream, "sha256").hexdigest()


def fetch(directory, name, url, checksum):
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / name
    if destination.is_file() and digest(destination) == checksum:
        return destination
    with tempfile.TemporaryDirectory(dir=directory) as scratch:
        download = Path(scratch) / name
        run(
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--retry",
            "2",
            url,
            "--output",
            download,
        )
        if digest(download) != checksum:
            raise ValueError(f"Checksum mismatch for {name}")
        download.replace(destination)
    return destination


def unpack(archive, destination):
    with tarfile.open(archive) as source:
        source.extractall(destination, filter="data")


@contextmanager
def build_lock(file):
    import fcntl

    with file.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def source_epoch():
    return int(os.environ.get("SOURCE_DATE_EPOCH", SOURCE_DATE_EPOCH))


def cross_toolchain(cache):
    host, checksum = TOOLCHAIN_HOSTS[sys.platform, machine()]
    name = f"llvm-mingw-{TOOLCHAIN_RELEASE}-ucrt-{host}"
    toolchain = cache / name
    with build_lock(cache / "llvm-mingw.lock"):
        if not (toolchain / "bin" / "x86_64-w64-mingw32-gcc").is_file():
            archive = fetch(
                cache / "downloads",
                f"{name}.tar.xz",
                f"https://github.com/mstorsjo/llvm-mingw/releases/download/{TOOLCHAIN_RELEASE}/{name}.tar.xz",
                checksum,
            )
            with tempfile.TemporaryDirectory(dir=cache) as scratch:
                unpack(archive, scratch)
                (Path(scratch) / name).replace(toolchain)
    return toolchain


def pinned_nsis_bottle(directory, host, checksum):
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / f"makensis-{NSIS_VERSION}-{host}.tar.gz"
    if archive.is_file() and digest(archive) == checksum:
        return archive
    repository = "homebrew/core/makensis"
    with urlopen(
        f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repository}:pull",
        timeout=20,
    ) as response:
        token = json.load(response)["token"]
    request = Request(f"https://ghcr.io/v2/{repository}/blobs/sha256:{checksum}")
    request.add_unredirected_header("Authorization", f"Bearer {token}")
    with tempfile.TemporaryDirectory(dir=directory) as scratch:
        downloaded = Path(scratch) / archive.name
        with urlopen(request, timeout=40) as response, downloaded.open("wb") as stream:
            shutil.copyfileobj(response, stream)
        if digest(downloaded) != checksum:
            raise ValueError("Checksum mismatch for the pinned NSIS installer compiler")
        downloaded.replace(archive)
    return archive


def installer_compiler(cache):
    current = shutil.which("makensis")
    if current:
        result = subprocess.run(
            [current, "-VERSION"], capture_output=True, text=True, check=False
        )
        if result.returncode == 0 and result.stdout.strip() == f"v{NSIS_VERSION}":
            return Path(current), os.environ.copy()
    bottle = NSIS_BOTTLES.get((sys.platform, machine()))
    if sys.platform == "darwin" and int(mac_ver()[0].partition(".")[0] or 0) < 27:
        bottle = None
    if bottle is None:
        raise ValueError(f"Install makensis {NSIS_VERSION} or use --format portable")
    host, checksum = bottle
    # Retain the default cache location on existing macOS workspaces.
    target = cache / "nsis" / "makensis" / NSIS_VERSION
    if sys.platform == "linux":
        target = target.with_name(f"{NSIS_VERSION}-{host}")
    cached_compiler = target / "bin" / "makensis"
    with build_lock(cache / "nsis.lock"):
        if not cached_compiler.is_file():
            archive = pinned_nsis_bottle(cache / "downloads", host, checksum)
            with tempfile.TemporaryDirectory(dir=cache) as scratch:
                unpack(archive, scratch)
                target.parent.mkdir(parents=True, exist_ok=True)
                (Path(scratch) / "makensis" / NSIS_VERSION).replace(target)
    return cached_compiler, os.environ | {"NSISDIR": str(target / "share" / "nsis")}


def pe_type(path):
    with path.open("rb") as stream:
        if stream.read(2) != b"MZ":
            raise ValueError(f"Invalid Windows executable: {path}")
        stream.seek(0x3C)
        header = struct.unpack("<I", stream.read(4))[0]
        stream.seek(header)
        if stream.read(4) != b"PE\x00\x00":
            raise ValueError(f"Invalid PE header: {path}")
        machine = struct.unpack("<H", stream.read(2))[0]
        stream.seek(header + 24 + 68)
        subsystem = struct.unpack("<H", stream.read(2))[0]
    return machine, subsystem


def verify_pe(path, expected_machine, expected_subsystem=None):
    machine, subsystem = pe_type(path)
    if machine != expected_machine or (
        expected_subsystem is not None and subsystem != expected_subsystem
    ):
        raise ValueError(
            f"Unexpected PE architecture or subsystem for {path}: {machine:#06x}, {subsystem}"
        )


def prepare_media(cache, toolchain, architecture):
    patch_root = REPOSITORY / "Scripts" / "Media"
    inputs = [PACKAGING / "prepare-media.sh", *sorted(patch_root.rglob("*.patch"))]
    key_material = (
        toolchain.name + str(source_epoch()) + "".join(digest(path) for path in inputs)
    )
    media = (
        cache / f"media-{architecture}-{sha256(key_material.encode()).hexdigest()[:16]}"
    )
    required = (
        "ffmpeg.exe",
        "ffprobe.exe",
        "COPYING.LGPLv2.1",
        "LAME-COPYING",
        "ZLIB-LICENSE",
    )
    with build_lock(media.with_suffix(".lock")):
        if not all((media / name).is_file() for name in required):
            with tempfile.TemporaryDirectory(dir=cache) as scratch:
                staging = Path(scratch) / "media"
                run(
                    PACKAGING / "prepare-media.sh",
                    staging,
                    architecture,
                    toolchain,
                    env=os.environ
                    | {
                        "DOWNAUDIBLE_WINDOWS_CACHE": str(cache),
                        "SOURCE_DATE_EPOCH": str(source_epoch()),
                    },
                )
                for executable in ("ffmpeg.exe", "ffprobe.exe"):
                    verify_pe(staging / executable, TARGETS[architecture]["machine"], 3)
                staging.replace(media)
        for executable in ("ffmpeg.exe", "ffprobe.exe"):
            verify_pe(media / executable, TARGETS[architecture]["machine"], 3)
    return media


def bundle_python(cache, root, architecture):
    target = TARGETS[architecture]
    platform = f"{target['cpu']}-pc-windows-msvc"
    name = f"cpython-{PYTHON_VERSION}+{PYTHON_RELEASE}-{platform}-install_only_stripped.tar.gz"
    archive = fetch(
        cache / "downloads",
        name,
        f"https://github.com/astral-sh/python-build-standalone/releases/download/{PYTHON_RELEASE}/{name}",
        target["python"],
    )
    unpack(archive, root)
    runtime = root / "python"
    (runtime / "python313._pth").write_text(
        ".\nLib\nDLLs\nsite-packages\n..\\resources\\Audible\nimport site\n",
        encoding="ascii",
    )
    shutil.rmtree(runtime / "Lib" / "site-packages", ignore_errors=True)
    shutil.rmtree(runtime / "Lib" / "test", ignore_errors=True)
    shutil.rmtree(runtime / "Scripts", ignore_errors=True)
    verify_pe(runtime / "python.exe", target["machine"], 3)
    verify_pe(runtime / "pythonw.exe", target["machine"], 2)
    uvx = shutil.which("uvx")
    if not uvx:
        raise ValueError(
            "Install uv and uvx to build the private Windows Python environment"
        )
    uv = (uvx, "--from", "uv==0.13.9", "uv")
    helper_dir = REPOSITORY / "Scripts" / "Audible"
    audible_requirements = run(
        *uv,
        "export",
        "--project",
        helper_dir,
        "--locked",
        "--no-dev",
        "--prune",
        "pyinstaller",
        "--format",
        "requirements-txt",
        capture_output=True,
    ).stdout
    install = (
        *uv,
        "pip",
        "install",
        "--target",
        runtime / "site-packages",
        "--python-version",
        "3.13",
        "--python-platform",
        platform,
        "--require-hashes",
        "--no-deps",
    )
    with tempfile.TemporaryDirectory() as scratch:
        scratch = Path(scratch)
        helper_lock = scratch / "audible.txt"
        helper_lock.write_bytes(audible_requirements)
        frontend_lock = scratch / "frontend.txt"
        frontend_lock.write_text(
            f"wxPython=={WX_VERSION} --hash=sha256:{target['wx']}\n"
            f"Markdown=={MARKDOWN_VERSION} --hash=sha256:{MARKDOWN_SHA256}\n",
            encoding="ascii",
        )
        constraints = scratch / "build-constraints.txt"
        constraints.write_text(SETUPTOOLS_BUILD_REQUIREMENT + "\n", encoding="ascii")
        run(*install, "--build-constraints", constraints, "-r", helper_lock)
        run(*install, "--only-binary", ":all:", "-r", frontend_lock)
    remove_host_scripts(runtime / "site-packages")
    (wx_core,) = (runtime / "site-packages" / "wx").glob("_core*.pyd")
    verify_pe(wx_core, target["machine"])
    return runtime


def remove_host_scripts(site_packages):
    scripts = site_packages / "bin"
    if not scripts.is_dir():
        return
    shutil.rmtree(scripts)
    for record in site_packages.glob("*.dist-info/RECORD"):
        with record.open(encoding="utf-8", newline="") as stream:
            rows = list(csv.reader(stream))
        kept = [row for row in rows if row and not row[0].startswith("bin/")]
        if len(kept) != len(rows):
            with record.open("w", encoding="utf-8", newline="") as stream:
                csv.writer(stream, lineterminator="\n").writerows(kept)


def windows_icon(scratch):
    icon = scratch / "DownAudible.ico"
    image = (REPOSITORY / "AppAssets" / "DownAudible.png").read_bytes()
    if len(image) < 24 or not image.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("The shared DownAudible app icon must be a PNG")
    width, height = struct.unpack_from(">II", image, 16)
    if not 1 <= width <= 256 or not 1 <= height <= 256:
        raise ValueError(
            "The shared DownAudible app icon must be no larger than 256 × 256 pixels"
        )
    icon.write_bytes(
        struct.pack(
            "<HHHBBBBHHII",
            0,
            1,
            1,
            width % 256,
            height % 256,
            0,
            0,
            1,
            32,
            len(image),
            22,
        )
        + image
    )
    return icon


def sign_executable(executable, signer):
    """Run the configured signer and require an embedded Authenticode certificate."""
    run(signer, executable)
    with executable.open("rb") as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise ValueError(
                f"The Windows signer did not leave a valid executable at {executable.name}."
            )
        (pe_offset,) = struct.unpack_from("<I", header, 0x3C)
        stream.seek(pe_offset)
        if stream.read(4) != b"PE\0\0":
            raise ValueError(
                f"The Windows signer did not leave a valid executable at {executable.name}."
            )
        optional_header = pe_offset + 24
        stream.seek(optional_header)
        magic = int.from_bytes(stream.read(2), "little")
        if magic in {0x10B, 0x20B}:
            stream.seek(optional_header + (128 if magic == 0x10B else 144))
            directory = stream.read(8)
            if len(directory) == 8:
                position, size = struct.unpack("<II", directory)
                if (
                    position
                    and size >= 8
                    and position + size <= executable.stat().st_size
                ):
                    stream.seek(position)
                    length, revision, kind = struct.unpack("<IHH", stream.read(8))
                    if 8 < length <= size and revision == 0x0200 and kind == 2:
                        return
    raise ValueError(
        f"The Windows signer did not embed an Authenticode signature in {executable.name}."
    )


def bundle_launcher(root, scratch, target, toolchain, icon, release):
    cross = toolchain / "bin" / f"{target['cpu']}-w64-mingw32"
    manifest = scratch / "launcher.manifest"
    template = (PACKAGING / "launcher.manifest").read_text(encoding="utf-8")
    manifest.write_text(
        template.replace("@FILE_VERSION@", release.file_version), encoding="utf-8"
    )
    rc = scratch / "launcher.rc"
    version_numbers = release.file_version.replace(".", ", ")
    rc.write_text(
        f"""1 ICON "{icon.name}"
1 24 "{manifest.name}"
1 VERSIONINFO
 FILEVERSION {version_numbers}
 PRODUCTVERSION {version_numbers}
 FILEOS 0x40004
 FILETYPE 0x1
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "CompanyName", "Ashley Cox"
            VALUE "FileDescription", "DownAudible"
            VALUE "FileVersion", "{release.file_version}"
            VALUE "OriginalFilename", "DownAudible.exe"
            VALUE "ProductName", "DownAudible"
            VALUE "ProductVersion", "{release.version}"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0409, 1200
    END
END
""",
        encoding="ascii",
    )
    obj = scratch / "launcher.res"
    run(f"{cross}-windres", "-i", rc.name, "-O", "coff", "-o", obj, cwd=scratch)
    application = root / "DownAudible.exe"
    run(
        f"{cross}-gcc",
        "-std=c17",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-municode",
        "-mwindows",
        "-Wl,--no-insert-timestamp",
        PACKAGING / "launcher.c",
        obj,
        "-o",
        application,
    )
    verify_pe(application, target["machine"], 2)
    return application


def app_resources(root, media, publisher):
    resources = root / "resources"
    sounds = resources / "Sounds"
    sounds.mkdir(parents=True)
    if publisher:
        (resources / "UpdatePublisher.txt").write_text(
            publisher + "\n", encoding="utf-8"
        )
    for sound in (REPOSITORY / "DownAudible" / "Resources").glob("Completion-*.wav"):
        shutil.copyfile(sound, sounds / sound.name)
    audible = resources / "Audible"
    audible.mkdir()
    for helper in ("audible_helper.py", "download_transfer.py", "widevine_download.py", "android_sign_in.py",
                   "audible_reports.py", "chapter_repair.py", "open_audible_import.py"):
        shutil.copyfile(REPOSITORY / "Scripts" / "Audible" / helper, audible / helper)
    shutil.copytree(media, resources / "Media")
    shutil.copytree(
        WINDOWS / "Manual",
        resources / "Manual",
        ignore=shutil.ignore_patterns(".DS_Store"),
    )
    bundle_manual(root)
    shutil.copyfile(
        REPOSITORY / "AppAssets" / "DownAudible.png", resources / "DownAudible.png"
    )
    shutil.copyfile(REPOSITORY / "LICENSE", root / "LICENSE.txt")


def bundle_manual(root):
    # Use the staged pure-Python Markdown package, without importing Windows extensions.
    run(
        sys.executable,
        "-I",
        "-B",
        "-c",
        """\
import sys
from pathlib import Path

source, site_packages, resources = sys.argv[1:]
sys.path[:0] = [source, site_packages]
from downaudible_windows.helpbook import build_help

resources = Path(resources)
build_help(resources / "Manual", resources / "Help")
""",
        WINDOWS,
        root / "python" / "site-packages",
        root / "resources",
    )


def write_portable_zip(root, archive, epoch):
    # DOS ZIP timestamps represent years 1980–2107 and have two-second precision.
    timestamp = time.gmtime(min(max(epoch, 315532800), 4354819198))[:6]
    with zipfile.ZipFile(
        archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
    ) as package:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                relative = path.relative_to(root.parent).as_posix()
                entry = zipfile.ZipInfo(relative, timestamp)
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = 0o100644 << 16
                entry.file_size = path.stat().st_size
                with path.open("rb") as source, package.open(entry, "w") as destination:
                    shutil.copyfileobj(source, destination)


def publish_artifacts(artifacts, output, name):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".{name}-", dir=output) as scratch:
        pending = [Path(scratch) / artifact.name for artifact in artifacts]
        for source, destination in zip(artifacts, pending, strict=True):
            shutil.copyfile(source, destination)
        with build_lock(output / f".{name}.lock"):
            for artifact in pending:
                final = output / artifact.name
                artifact.replace(final)
                print(f"{final}    SHA-256 {digest(final)}", flush=True)


def build(
    cache,
    output,
    architecture,
    package_format,
    toolchain,
    media,
    release,
    publisher,
    signer,
):
    source = WINDOWS / "downaudible_windows"
    if not (source / "__main__.py").is_file():
        raise ValueError("The Windows app entry point is missing")
    bundle_name = f"DownAudible-{release.version}-windows-{architecture}"
    with tempfile.TemporaryDirectory(prefix="downaudible-win-package-") as scratch:
        scratch = Path(scratch)
        root = scratch / bundle_name
        root.mkdir()
        runtime = bundle_python(cache, root, architecture)
        package = runtime / source.name
        shutil.copytree(
            source,
            package,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"),
        )
        (package / "release.json").write_text(
            json.dumps({"version": release.version, "build": release.build}) + "\n",
            encoding="utf-8",
        )
        app_resources(root, media, publisher)
        icon = windows_icon(scratch)
        launcher = bundle_launcher(
            root, scratch, TARGETS[architecture], toolchain, icon, release
        )
        if signer:
            sign_executable(launcher, signer)
        artifacts = []
        if package_format in ("both", "installer"):
            makensis, environment = installer_compiler(cache)
            installer = scratch / windows_asset_name(architecture, "installer")
            run(
                makensis,
                "-V2",
                f"-DOUTPUT={installer}",
                f"-DBUNDLE={root}",
                f"-DICON={icon}",
                f"-DVERSION={release.version}",
                f"-DBUILD={release.build}",
                f"-DARCH={architecture}",
                PACKAGING / "installer.nsi",
                env=environment | {"SOURCE_DATE_EPOCH": str(source_epoch())},
            )
            # NSIS uses a 32-bit bootstrapper for both native Windows payloads.
            verify_pe(installer, 0x014C, 2)
            if signer:
                sign_executable(installer, signer)
            artifacts.append(installer)
        if package_format in ("both", "portable"):
            archive = scratch / windows_asset_name(architecture, "portable")
            write_portable_zip(root, archive, source_epoch())
            artifacts.append(archive)
        publish_artifacts(artifacts, output, f"DownAudible-Windows-{architecture}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("x64", "arm64", "both"), default="both")
    parser.add_argument(
        "--format", choices=("portable", "installer", "both"), default="both"
    )
    parser.add_argument("--output", type=Path, default=WINDOWS / "dist")
    parser.add_argument(
        "--update-publisher",
        default="",
        help="Exact Authenticode certificate subject trusted for Windows updates",
    )
    parser.add_argument(
        "--sign-with",
        metavar="SIGNER",
        help="Executable that applies a timestamped Authenticode signature to a Windows file in place",
    )
    parser.add_argument(
        "--media-only",
        action="store_true",
        help="Build the patched Windows media tools into the cache",
    )
    options = parser.parse_args()
    publisher = options.update_publisher.strip()
    if "\n" in publisher or "\r" in publisher:
        parser.error("the update publisher must be a single certificate subject")
    signer = None
    if options.sign_with:
        if options.media_only or not publisher:
            parser.error("--sign-with requires a packaged build and --update-publisher")
        signer = shutil.which(str(Path(options.sign_with).expanduser()))
        if not signer:
            parser.error("the signing executable could not be found")
        signer = Path(signer).resolve()
    if (sys.platform, machine()) not in TOOLCHAIN_HOSTS:
        parser.error(
            "build on macOS or in an x64 or ARM64 Ubuntu environment such as WSL 2"
        )
    cache = (
        Path(
            os.environ.get(
                "DOWNAUDIBLE_WINDOWS_CACHE",
                Path(tempfile.gettempdir()) / "downaudible-windows",
            )
        )
        .expanduser()
        .resolve()
    )
    cache.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("SOURCE_DATE_EPOCH", str(SOURCE_DATE_EPOCH))
    architectures = TARGETS if options.arch == "both" else (options.arch,)
    try:
        if not 0 <= source_epoch() <= 253402300799:
            raise ValueError(
                "SOURCE_DATE_EPOCH must be a Unix timestamp between 1970 and 9999"
            )
        release = read_xcconfig(REPOSITORY / "App.xcconfig")
        toolchain = cross_toolchain(cache)
        for architecture in architectures:
            media = prepare_media(cache, toolchain, architecture)
            if options.media_only:
                print(media, flush=True)
            else:
                build(
                    cache,
                    options.output.resolve(),
                    architecture,
                    options.format,
                    toolchain,
                    media,
                    release,
                    publisher,
                    signer,
                )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()

"""The version and build shared by the macOS and Windows packages."""

import json
import re
from dataclasses import dataclass
from pathlib import Path


def windows_asset_name(architecture: str, package_format: str) -> str:
    architecture_label = {"arm64": "ARM64", "x64": "x64"}[architecture]
    suffix = {"installer": "Installer.exe", "portable": "Portable.zip"}[package_format]
    return f"DownAudible-Windows-{architecture_label}-{suffix}"


@dataclass(frozen=True, slots=True)
class Release:
    version: str
    build: int

    def __post_init__(self):
        if not isinstance(self.version, str) or not re.fullmatch(
            r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}", self.version
        ):
            raise ValueError("DownAudible needs a three-part numeric release version.")
        if type(self.build) is not int or not 1 <= self.build <= 65535:
            raise ValueError(
                "The DownAudible build number must be between 1 and 65535."
            )
        if any(len(part) > 5 or int(part) > 65535 for part in self.version.split(".")):
            raise ValueError(
                "Each release version component must fit in a Windows version resource."
            )

    @property
    def file_version(self):
        return f"{self.version}.{self.build}"


def read_xcconfig(path: Path) -> Release:
    source = path.read_text(encoding="utf-8")

    def value(name):
        matches = re.findall(
            rf"^[ \t]*{name}[ \t]*=[ \t]*([^/\s]+)[ \t]*(?://[^\r\n]*)?$",
            source,
            flags=re.MULTILINE,
        )
        if len(matches) != 1:
            raise ValueError(f"Set {name} exactly once in {path.name}.")
        return matches[0]

    build = value("CURRENT_PROJECT_VERSION")
    if not re.fullmatch(r"[1-9][0-9]{0,4}", build):
        raise ValueError(
            "CURRENT_PROJECT_VERSION must be a positive Windows build number."
        )
    return Release(value("MARKETING_VERSION"), int(build))


def installed_release() -> Release:
    module = Path(__file__).resolve()
    packaged = module.with_name("release.json")
    if packaged.is_file():
        return Release(**json.loads(packaged.read_text(encoding="utf-8")))
    return read_xcconfig(module.parents[2] / "App.xcconfig")

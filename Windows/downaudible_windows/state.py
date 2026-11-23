"""Per-user settings and atomic state files."""

import json
import os
import tempfile
from copy import deepcopy
from pathlib import Path

DEFAULT_FOLDER_TEMPLATE = r"{format}\{author}\{title}"

DEFAULT_CONVERSION = {
    "format": "m4b", "chapter_mode": "single", "audio_mode": "automatic",
    "bitrate": 0, "channels": 0, "sample_rate": 0, "mp3_bitrate_mode": "automatic",
    "mp3_quality": 2, "embed_artwork": True, "preserve_metadata": True,
    "embed_chapters": True, "copy_chapter_audio": False, "move_aax_to_trash": False,
}
DEFAULT_DOWNLOAD = {
    "downloadAudio": True, "convert": False, "keepOriginal": True,
    "downloadPDF": False, "downloadCover": False, "downloadChapters": False,
    "downloadAnnotations": False, "open_after_saving": "off",
}
OPEN_AFTER_SAVING = (
    ("off", "Off"),
    ("original", "Original Audible audio in the default player"),
    ("converted", "Converted audio in the default player"),
)
DEFAULT_API = {
    "quality": "best", "format": "preferAAX", "preferWholeBookDownloads": True,
    "coverSizes": [], "chapterStyle": "tree", "podcasts": "ignore", "pageSize": 100,
    "purchaseStart": "", "purchaseEnd": "",
}
FEEDBACK_EVENTS = {
    "downloadCompleted": "Download Completed", "conversionCompleted": "Conversion Completed",
    "downloadFailed": "Download Failed", "conversionFailed": "Conversion Failed",
    "queueFinished": "Queue Finished",
}
DEFAULTS = {
    "setup_complete": False, "show_help_tags": True, "show_sidebar": True, "show_status": True,
    "check_updates": False, "update_choice_made": False, "install_updates": False,
    "audible_accounts": [], "audible_account": None,
    "api": DEFAULT_API, "download": DEFAULT_DOWNLOAD, "conversion": DEFAULT_CONVERSION,
    "archive_root": "", "folder_template": DEFAULT_FOLDER_TEMPLATE, "filename_template": "",
    "chapter_filename_template": "{title} - {chapterNumber} - {chapter}",
    "keep_aax_filename": False, "filename_style": "unicode",
    "max_filename_bytes": 230, "filename_spaces": "keep", "filename_case": "original",
    "ascii_names": False, "existing_files": "reuse",
    "download_limit": 3, "conversion_limit": 2, "timeout": 45, "bandwidth": 0,
    "daily_download_limit": {"scope": "off", "unit": "books", "quantity": 50},
    "continue_after_error": True, "show_progress": True, "log_level": "off", "log_file": "",
    "notifications": {}, "filter_suggestions": True, "matches": {}, "match_folders": {},
    "background_library_refresh": False, "saved_library_views": {}, "library_tags": {},
    "audiobookshelf": {"server": "", "library_id": "", "folder_id": "", "auto_upload": False, "include_pdf": False},
}


def default_archive() -> Path:
    return Path.home() / "Documents" / "Audiobooks"


def native_folder_template(template: str) -> str:
    return template.replace("/", "\\")


def app_data() -> Path:
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / "DownAudible"
    return Path.home() / "Library" / "Application Support" / "DownAudible Windows Preview"


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(prefix=f".{path.stem}-", suffix=".tmp", dir=path.parent)
    temp = Path(temp_name)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def load_settings(path: Path) -> dict:
    defaults = deepcopy(DEFAULTS)
    saved = read_json(path)
    if saved is not None:
        if not isinstance(saved, dict):
            raise ValueError("Settings must contain a JSON object.")
        for key, current in saved.items():
            if isinstance(defaults.get(key), dict) and isinstance(current, dict):
                defaults[key].update(current)
            else:
                defaults[key] = current
        if "update_choice_made" not in saved and saved.get("check_updates"):
            defaults["update_choice_made"] = True
    if not defaults["archive_root"]:
        defaults["archive_root"] = str(default_archive())
    if isinstance(defaults["folder_template"], str):
        defaults["folder_template"] = native_folder_template(defaults["folder_template"])
    return defaults


def api_options(settings: dict) -> dict:
    options = dict(settings["api"])
    options["timeout"] = settings["timeout"]
    options["bytesPerSecond"] = settings["bandwidth"] * 1000 // 8
    for name in ("purchaseStart", "purchaseEnd"):
        if not options.get(name):
            options.pop(name, None)
    return options

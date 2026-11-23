"""Validate Audible chapter JSON and prepare chapter markers without audio access."""

import json
import re
from pathlib import Path

from audible.exceptions import NotFoundError
from audible_cli.models import LibraryItem
from download_transfer import OperationError

MAX_FILE_SIZE = 4 * 1024 * 1024
MAX_RUNTIME_MS = 30 * 24 * 60 * 60 * 1_000
ASIN = re.compile(r"[A-Za-z0-9]{10}", re.ASCII)


def read_chapter_repair(path, expected_asin):
    try:
        with Path(path).open("rb") as source:
            data = source.read(MAX_FILE_SIZE + 1)
        if len(data) > MAX_FILE_SIZE:
            raise OperationError("chapterRepairMetadata")
        metadata = json.loads(data)
    except OSError as error:
        raise OperationError("chapterRepairFile") from error
    except (ValueError, RecursionError) as error:
        raise OperationError("chapterRepairMetadata") from error
    return chapter_repair(metadata, expected_asin=expected_asin)


async def fetch_chapter_repair(client, asin, quality):
    try:
        metadata = await LibraryItem({"asin": asin}, client).get_content_metadata(quality, chapter_type="Flat")
    except NotFoundError as error:
        raise OperationError("chapterRepairMetadata") from error
    return chapter_repair(metadata, expected_asin=asin, requested_asin=asin)


def chapter_repair(metadata, *, expected_asin=None, requested_asin=None):
    if not isinstance(metadata, dict):
        raise OperationError("chapterRepairMetadata")
    content = metadata
    license_data = metadata.get("content_license")
    if isinstance(license_data, dict):
        content = license_data
    content = content.get("content_metadata", content)
    if not isinstance(content, dict):
        raise OperationError("chapterRepairMetadata")
    info = content.get("chapter_info", content)
    if not isinstance(info, dict) or info.get("is_accurate") is False:
        raise OperationError("chapterRepairMetadata")

    reference = content.get("content_reference")
    candidates = [metadata.get("asin"), content.get("asin"), info.get("asin")]
    if isinstance(reference, dict):
        candidates.append(reference.get("asin"))
    identifiers = {value.upper() for value in candidates if isinstance(value, str) and ASIN.fullmatch(value)}
    if expected_asin:
        identifiers.add(expected_asin.upper())
    if len(identifiers) > 1:
        raise OperationError("chapterRepairEdition")
    identifier = requested_asin or expected_asin or next(
        (value.upper() for value in candidates if isinstance(value, str) and ASIN.fullmatch(value)), None
    )

    runtime = info.get("runtime_length_ms")
    if type(runtime) is not int or not 0 < runtime <= MAX_RUNTIME_MS:
        raise OperationError("chapterRepairMetadata")
    leaves = list(_markers(info.get("chapters")))
    leaves.sort(key=lambda item: item["startMilliseconds"])
    if not leaves:
        raise OperationError("chapterRepairMetadata")
    end = 0
    for marker in leaves:
        start = marker["startMilliseconds"]
        duration = marker["durationMilliseconds"]
        if start < end or start + duration > runtime:
            raise OperationError("chapterRepairMetadata")
        end = start + duration

    result = {"runtimeMilliseconds": runtime, "chapters": leaves}
    if identifier:
        result["asin"] = identifier
    intro = info.get("brandIntroDurationMs", 0)
    outro = info.get("brandOutroDurationMs", 0)
    if (type(intro) is int and type(outro) is int and intro >= 0 and outro >= 0
            and 0 < intro + outro < runtime):
        separated = []
        for marker in leaves:
            start = max(marker["startMilliseconds"], intro)
            end = min(marker["startMilliseconds"] + marker["durationMilliseconds"], runtime - outro)
            if end > start:
                separated.append(_marker(start, end - start, marker["title"]))
        if separated:
            if intro:
                separated.insert(0, _marker(0, intro, "Audible Intro"))
            if outro:
                separated.append(_marker(runtime - outro, outro, "Audible Outro"))
            result["separatedChapters"] = separated
    return result


def _markers(value, depth=0):
    if not isinstance(value, list) or depth > 16:
        raise OperationError("chapterRepairMetadata")
    for entry in value:
        if not isinstance(entry, dict):
            raise OperationError("chapterRepairMetadata")
        if entry.get("chapters"):
            yield from _markers(entry["chapters"], depth + 1)
            continue
        start = entry.get("start_offset_ms")
        duration = entry.get("length_ms")
        title = entry.get("title")
        if (type(start) is not int or type(duration) is not int or start < 0
                or duration <= 0 or not isinstance(title, str) or not title.strip()):
            raise OperationError("chapterRepairMetadata")
        yield _marker(start, duration, title.strip())


def _marker(start, duration, title):
    return {"startMilliseconds": start, "durationMilliseconds": duration, "title": title}

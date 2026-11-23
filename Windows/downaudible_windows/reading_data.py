"""Annotation filtering and portable reading exports."""

import csv
import io
import re
import unicodedata
from dataclasses import dataclass
from datetime import date

from .library_catalog import PROGRESS, progress_label

GOODREADS_HEADERS = ("Title", "Author", "ISBN", "ASIN", "Exclusive Shelf", "Date Added", "Date Read")
GOODREADS_SHELVES = dict(zip(PROGRESS, ("to-read", "currently-reading", "read", ""), strict=True))
ANNOTATION_TYPES = {"bookmark": "Bookmark", "note": "Note"}


def _csv_data(headers, rows):
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(headers)
    writer.writerows([_spreadsheet_text(value) for value in row] for row in rows)
    return output.getvalue().encode("utf-8")


def _spreadsheet_text(value):
    if value.startswith(("\t", "\n", "\r")) or value.lstrip().startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def _valid_isbn(value):
    normalized = value.strip().replace("-", "").replace(" ", "").upper() if isinstance(value, str) else ""
    if re.fullmatch(r"[0-9]{9}[0-9X]", normalized):
        total = sum((10 - index) * (10 if digit == "X" else int(digit)) for index, digit in enumerate(normalized))
        return normalized if total % 11 == 0 else ""
    if re.fullmatch(r"97[89][0-9]{10}", normalized):
        total = sum((3 if index % 2 else 1) * int(digit) for index, digit in enumerate(normalized))
        return normalized if total % 10 == 0 else ""
    return ""


def _valid_asin(value):
    if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9]{10}", value.strip()):
        return value.strip().upper()
    return ""


def _date_added(value):
    if not isinstance(value, str) or not re.match(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:$|T)", value):
        return ""
    try:
        return date.fromisoformat(value[:10]).isoformat().replace("-", "/")
    except ValueError:
        return ""


@dataclass(frozen=True)
class GoodreadsRow:
    title: str
    identifier: str
    status: str
    listening: str
    values: tuple[str, ...] | None = None


def goodreads_rows(books):
    """Preserve library order and explain each excluded edition in the preview."""
    seen = set()
    rows = []
    for book in books:
        isbn, asin = _valid_isbn(book.get("isbn")), _valid_asin(book.get("asin"))
        identifier = f"ISBN {isbn}" if isbn else f"ASIN {asin}" if asin else ""
        title = book.get("title") or asin or isbn or "Untitled book"
        listening = progress_label(book)
        if not identifier:
            rows.append(GoodreadsRow(title, "", "No valid ISBN or ASIN", listening))
            continue
        identifiers = {(kind, value) for kind, value in (("isbn", isbn), ("asin", asin)) if value}
        duplicate = bool(seen.intersection(identifiers))
        seen.update(identifiers)
        if duplicate:
            rows.append(GoodreadsRow(title, identifier, "Duplicate edition", listening))
            continue
        authors = ", ".join(book.get("authors") or ())
        shelf = GOODREADS_SHELVES[listening]
        values = (title, authors, isbn, "" if isbn else asin, shelf, _date_added(book.get("dateAdded")), "")
        rows.append(GoodreadsRow(title, identifier, "Ready", listening, values))
    return rows


def goodreads_data(rows):
    return _csv_data(GOODREADS_HEADERS, (row.values for row in rows if row.values is not None))


@dataclass(frozen=True)
class Annotation:
    kind: str
    milliseconds: int | None
    text: str

    @property
    def type_label(self):
        return ANNOTATION_TYPES[self.kind]

    @property
    def position_label(self):
        if self.milliseconds is None:
            return ""
        hours, remainder = divmod(self.milliseconds // 1000, 3600)
        minutes, seconds = divmod(remainder, 60)
        return f"{hours}:{minutes:02d}:{seconds:02d}"


def annotation_rows(entries):
    rows = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        kind = entry.get("kind")
        if kind not in ANNOTATION_TYPES:
            continue
        position = entry.get("positionMilliseconds")
        text = entry.get("text")
        rows.append(Annotation(kind, position if type(position) is int and position >= 0 else None,
                               text if isinstance(text, str) else ""))
    return sorted(rows, key=lambda row: (row.milliseconds is None, row.milliseconds or 0))


def filter_annotations(rows, query):
    def search_text(text):
        return "".join(char for char in unicodedata.normalize("NFKD", text.casefold()) if not unicodedata.combining(char))

    words = search_text(query).split()
    matching = []
    for row in rows:
        text = search_text(f"{row.type_label} {row.position_label} {row.text}")
        if all(word in text for word in words):
            matching.append(row)
    return matching


def annotation_data(title, rows, extension):
    if extension == ".csv":
        return _csv_data(("Type", "Position", "Text"), ((row.type_label, row.position_label, row.text) for row in rows))
    heading = re.sub(r"([\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e])", r"\\\1", " ".join(title.split()))
    # Indented blocks preserve note text without turning it into Markdown or HTML.
    sections = [f"# {heading}"]
    for row in rows:
        label = " · ".join(part for part in (row.type_label, row.position_label) if part)
        note = "\n".join(f"    {line}" for line in row.text.splitlines())
        sections.append(f"## {label}" + (f"\n\n{note}" if note else ""))
    return ("\n\n".join(sections) + "\n").encode("utf-8")

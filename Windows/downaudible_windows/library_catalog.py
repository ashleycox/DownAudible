"""Profile-scoped catalogue snapshots and local library organisation."""

from datetime import UTC, datetime
from hashlib import sha256
from math import isfinite

from .state import read_json, write_json

ACCESS = ("Indefinite Access", "Audible Plus", "Other Titles", "Unknown")
PROGRESS = ("Not Started", "In Progress", "Finished", "Unknown")
CATALOGUE_OPTIONS = ("podcasts", "purchaseStart", "purchaseEnd")


def profile_id(book, fallback=None):
    return book.get("_account_id") or fallback


def book_identity(book, fallback=None):
    return profile_id(book, fallback), book["asin"]


def access_label(book):
    plus = book.get("isAudiblePlus")
    indefinite = book.get("isIndefinite")
    if plus is True:
        return ACCESS[1]
    if indefinite is True:
        return ACCESS[0]
    return ACCESS[2] if plus is False and indefinite is False else ACCESS[3]


def progress_label(book):
    if book.get("isFinished") is True:
        return PROGRESS[2]
    value = book.get("percentComplete")
    if type(value) not in (int, float) or not isfinite(value) or not 0 <= value <= 100:
        return PROGRESS[3]
    return PROGRESS[2] if value == 100 else PROGRESS[1] if value > 0 else PROGRESS[0]


def parse_tags(value):
    labels = {}
    for item in value.split(","):
        label = " ".join(item.split())
        if label:
            labels.setdefault(label.casefold(), label)
    if len(labels) > 40 or any(len(label) > 60 for label in labels.values()):
        raise ValueError("Use up to 40 tags, with no more than 60 characters in each tag.")
    return list(labels.values())


def tagged_book(book, account, tags):
    return dict(book, _account_id=account["id"], accountName=account["name"], marketplace=account["marketplace"],
                tags=tags.get(account["id"], {}).get(book["asin"], []))


class Catalogue:
    def __init__(self, folder):
        self.folder = folder
        self.entries = {}

    def path(self, account_id):
        name = sha256(account_id.encode("utf-8")).hexdigest()
        return self.folder / f"{name}.json"

    def get(self, account_id):
        if not account_id:
            return None
        if account_id not in self.entries:
            try:
                value = read_json(self.path(account_id))
                if (not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("books"), list)
                        or not isinstance(value.get("options"), dict) or not isinstance(value.get("date"), str)
                        or not isinstance(value.get("changes"), list)
                        or any(not isinstance(book, dict) or not isinstance(book.get("asin"), str) for book in value["books"])
                        or any(not isinstance(change, dict) or not isinstance(change.get("title"), str)
                               or not isinstance(change.get("change"), str) for change in value["changes"])):
                    value = None
            except (OSError, ValueError, TypeError, RecursionError):
                value = None
            self.entries[account_id] = value
        return self.entries[account_id]

    def record(self, account_id, books, options, *, persist=True, now=None):
        old = self.get(account_id) if persist else self.entries.get(account_id)
        scope = {key: options.get(key) for key in CATALOGUE_OPTIONS}
        books = list({book["asin"]: dict(book) for book in books}.values())
        changes = []
        if old and old["options"] == scope:
            previous = {book["asin"]: book for book in old["books"]}
            current = {book["asin"]: book for book in books}
            for items, other, label in ((current, previous, "Added"), (previous, current, "No longer listed")):
                changes.extend({"title": book.get("title") or asin, "asin": asin, "change": label}
                               for asin, book in items.items() if asin not in other)
        entry = {"version": 1, "date": (now or datetime.now(UTC)).isoformat(), "options": scope,
                 "books": books, "changes": changes}
        # Keep a usable in-memory snapshot if the local data folder cannot be written.
        self.entries[account_id] = entry
        if persist:
            write_json(self.path(account_id), entry)
        return entry

    def remove(self, account_id):
        self.entries[account_id] = None
        self.path(account_id).unlink(missing_ok=True)


def refresh_label(snapshot, prefix="Last refreshed "):
    try:
        instant = datetime.fromisoformat(snapshot["date"]).astimezone()
        return f"{prefix}{instant:%d %b %Y at %H:%M}"
    except (KeyError, TypeError, ValueError, OverflowError):
        return "Never refreshed"

"""Rolling limits for new Audible audio requests."""

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from math import isfinite
from threading import RLock
from time import time

from .state import read_json, write_json

WINDOW_SECONDS = 24 * 60 * 60
UNITS = {"books": 1, "mb": 1_000_000, "gb": 1_000_000_000}
MAX_LIMIT = 100_000


class DownloadDeferred(Exception):
    def __init__(self, until=None):
        super().__init__("Waiting for the daily download limit.")
        self.until = until


@dataclass(frozen=True)
class DownloadLimit:
    scope: str = "off"
    unit: str = "books"
    quantity: int = 50

    @classmethod
    def read(cls, values):
        if not isinstance(values, dict):
            return cls()
        scope, unit, quantity = (values.get(name) for name in ("scope", "unit", "quantity"))
        return cls(
            scope if scope in ("off", "all", "plus") else "off",
            unit if isinstance(unit, str) and unit in UNITS else "books",
            min(max(quantity, 1), MAX_LIMIT) if type(quantity) is int else 50,
        )

    def applies(self, plus):
        return self.scope == "all" or (self.scope == "plus" and plus)

    @property
    def capacity(self):
        return self.quantity * UNITS[self.unit]


@dataclass(frozen=True)
class Usage:
    time: float
    job: str
    plus: bool
    books: int
    bytes: int

    @classmethod
    def read(cls, values):
        entry = cls(**values)
        if (type(entry.time) not in (int, float) or not isfinite(entry.time) or not isinstance(entry.job, str)
                or not entry.job or type(entry.plus) is not bool or type(entry.books) is not int or entry.books not in (0, 1)
                or type(entry.bytes) is not int or entry.bytes < 1):
            raise ValueError("Invalid daily download usage entry.")
        datetime.fromtimestamp(entry.time + WINDOW_SECONDS).astimezone()
        return entry


class DownloadPacer:
    def __init__(self, path, *, clock=time):
        self.path = path
        self.clock = clock
        self.lock = RLock()
        self.policy = DownloadLimit()
        self.active = {}
        self.read_error = None
        try:
            saved = read_json(path)
            if saved is not None and not isinstance(saved, list):
                raise ValueError("Invalid daily download usage format.")
            self.usage = [Usage.read(row) for row in saved] if saved is not None else []
        except (OSError, TypeError, ValueError, OverflowError, RecursionError) as error:
            self.usage = []
            self.read_error = error

    def configure(self, values):
        policy = DownloadLimit.read(values)
        with self.lock:
            changed = self.policy != policy
            self.policy = policy
            return changed

    def _admit(self, job, plus, now):
        policy = self.policy
        if not policy.applies(plus):
            return
        if self.read_error is not None:
            raise OSError("DownAudible couldn’t read its daily download usage. Check the application data folder.") from self.read_error
        if policy.unit == "books" and any(entry.job == job and entry.books for entry in self.usage):
            return
        usages = sorted((entry for entry in self.usage if policy.applies(entry.plus)), key=lambda entry: entry.time)
        amounts = [entry.books if policy.unit == "books" else entry.bytes for entry in usages]
        used = sum(amounts)
        if used >= policy.capacity:
            for entry, amount in zip(usages, amounts, strict=True):
                used -= amount
                if used < policy.capacity:
                    raise DownloadDeferred(entry.time + WINDOW_SECONDS)
        pending = sum(policy.applies(included) for included in self.active.values())
        if pending and (policy.unit != "books" or used + pending >= policy.capacity):
            raise DownloadDeferred()

    @contextmanager
    def reserve(self, job, *, plus=False):
        plus = plus is True
        with self.lock:
            now = self.clock()
            self._prune(now)
            self._admit(job, plus, now)
            self.active[job] = plus
        try:
            yield lambda received: self.record(job, plus, received)
        finally:
            with self.lock:
                self.active.pop(job, None)

    def _prune(self, now):
        self.usage = [entry for entry in self.usage if entry.time + WINDOW_SECONDS > now]

    def record(self, job, plus, received):
        if not received:
            return
        with self.lock:
            now = self.clock()
            self._prune(now)
            first = not any(entry.job == job and entry.books for entry in self.usage)
            self.usage.append(Usage(now, job, plus, int(first), received))
            if self.read_error is not None:
                return
            try:
                write_json(self.path, [vars(entry) for entry in self.usage])
            except OSError as error:
                if self.policy.applies(plus):
                    raise OSError("DownAudible couldn’t save its daily download usage. Check the application data folder.") from error

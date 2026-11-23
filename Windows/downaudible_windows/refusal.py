"""Retry times for explicit Audible service refusals, separate from local pacing."""

from datetime import datetime
from math import isfinite
from threading import RLock
from time import time

from .state import read_json, write_json

RETRY_WINDOWS = {"rateLimited": 15 * 60, "licenseThrottled": 60 * 60, "serverUnavailable": 5 * 60}


class RetryAfter(Exception):
    def __init__(self, until, reason, *, new=False):
        self.until, self.reason, self.new = until, reason, new
        super().__init__(reason)

    def detail(self, *, automatic=True):
        retry = datetime.fromtimestamp(self.until).astimezone()
        action = "Next retry" if automatic else "Try again after"
        return f"{action} {retry:%d %b %Y at %H:%M}. {self.reason}"


class Refusals:
    def __init__(self, path, *, clock=time):
        self.path = path
        self.clock = clock
        self.lock = RLock()
        try:
            saved = read_json(path)
            self.entries = {
                key: (until, reason) for key, (until, reason) in (saved or {}).items()
                if type(until) in (int, float) and isfinite(until) and clock() < until <= clock() + max(RETRY_WINDOWS.values())
                and reason in RETRY_WINDOWS
            }
        except (OSError, TypeError, ValueError, AttributeError):
            self.entries = {}

    def check(self, account, message):
        with self.lock:
            if account and (entry := self.entries.get(account)) and entry[0] > self.clock():
                raise RetryAfter(entry[0], message(entry[1]))

    def record(self, account, code, message):
        if not account or code not in RETRY_WINDOWS:
            return
        with self.lock:
            now = self.clock()
            until = now + RETRY_WINDOWS[code]
            previous = self.entries.get(account)
            if previous and previous[0] > until:
                until = previous[0]
            self.entries = {key: value for key, value in self.entries.items() if value[0] > now}
            self.entries[account] = until, code
            try:
                write_json(self.path, self.entries)
            except OSError:
                pass  # The in-memory pause still protects this session.
        raise RetryAfter(until, message, new=True)

"""Windows Audible library and native library controls."""

from __future__ import annotations

import csv
import io
import json
import re
import threading
import unicodedata
from contextlib import nullcontext
from datetime import date, datetime, time, timezone
from pathlib import Path

import wx

from .audible import MARKETPLACES, AudibleClient, AudibleError, demo_books, write_atomic
from .audible_dialogs import (
    NO_ACCOUNTS,
    AccountsDialog,
    ImportAccountDialog,
    SignInDialog,
    accessible_name,
    button,
    run_async,
    show_error,
)
from .cue import supports_cue
from .library_catalog import (
    ACCESS,
    PROGRESS,
    Catalogue,
    access_label,
    book_identity,
    parse_tags,
    profile_id,
    progress_label,
    refresh_label,
    tagged_book,
)
from .purchase_dates import purchase_date_options
from .refusal import RetryAfter
from .report_list import report_list
from .spreadsheet import workbook_data
from .state import DEFAULT_DOWNLOAD

FILTER_FIELDS = {
    "Title": "title", "Author": "authors", "Series": "series", "Narrator": "narrators",
    "Genre": "genres", "Language": "language", "Release Year": "releaseYear", "Download Status": "status",
    "Tag": "tags", "Access": "access", "Listening Progress": "listeningProgress",
}
STATUS_ORDER = ("Not downloaded", "Incomplete", "Files missing", "Downloaded", "Matched", "Unavailable")
STATUS_GROUPS = {
    "All Audiobooks": "Compare saved audio with the titles Audible offers for download.",
    "To Download": "These titles are available from Audible and still need a local copy.",
    "Downloaded": "At least one complete audio copy is saved in your archive.",
    "Matched": "Audio is available from a file or folder you linked to the Library.",
    "Unavailable": "These titles need a local copy and Audible marks them as unavailable to download.",
}
AVAILABILITY = {"podcastSeries": "Podcast series", "offlineRestricted": "Offline restricted", "unpublished": "Unpublished"}
COLUMNS = (
    ("Title", "title", 240), ("Author", "authors", 132), ("Narrator", "narrators", 133),
    ("Download Status", "status", 133),
    ("Series", "series", 130), ("Purchase Date", "purchaseDate", 115), ("Release Year", "releaseYear", 92),
    ("Length", "durationSeconds", 85),
    ("Account", "accountName", 145),
)
LEGACY_COLUMN_FIELDS = ("title", "authors", "narrators", "series", "purchaseDate", "releaseYear", "durationSeconds", "status")
EXPORT_COLUMNS = (
    ("ASIN", "asin"), ("Title", "title"), ("Subtitle", "subtitle"), ("Authors", "authors"),
    ("Narrators", "narrators"), ("Series", "series"), ("Series Number", "seriesSequence"),
    ("Publisher", "publisher"), ("Language", "language"), ("Genres", "genres"),
    ("Release Date", "releaseDate"), ("Date Added", "dateAdded"), ("Duration (Seconds)", "durationSeconds"),
    ("Rating", "rating"), ("Rating Count", "ratingCount"), ("Finished", "isFinished"),
    ("Percent Complete", "percentComplete"), ("Cover", "coverURL"), ("Description", "description"),
)
LIBRARY_ONLY_COLUMNS = (("Purchased", "purchaseDate"), ("PDF Available", "hasPDF"), ("Download Available", "isDownloadable"),
                        ("Account", "accountName"), ("Marketplace", "marketplace"), ("Audible Plus", "isAudiblePlus"), ("Tags", "tags"))
EXPORT_FORMATS = ((".json", "JSON files"), (".csv", "CSV files"), (".tsv", "TSV files"), (".xlsx", "Excel workbooks"))


def cell_value(book, field, status_for):
    if field == "releaseYear":
        match = re.match(r"^([0-9]{4})(?:-|$)", book.get("releaseDate") or "")
        if match and int(match[1]) > 0:
            return str(int(match[1]))
        return ""
    if field == "status":
        return status_for(book)
    if field == "access":
        return access_label(book)
    if field == "listeningProgress":
        return progress_label(book)
    return book.get(field)


def label(value):
    if value is None:
        return ""
    if isinstance(value, list):
        return ", ".join(map(str, value))
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


def display_time(seconds):
    if seconds is None:
        return ""
    hours, minutes = divmod(int(seconds) // 60, 60)
    return f"{hours} hr {minutes} min" if hours else f"{minutes} min"


def display_cell(book, field, status_for):
    value = cell_value(book, field, status_for)
    return display_time(value) if field == "durationSeconds" else label(value)


def normalized(text):
    return "".join(character for character in unicodedata.normalize("NFKD", text.casefold())
                   if not unicodedata.combining(character))


def natural_key(text):
    return tuple(int(part) if index % 2 else part
                 for index, part in enumerate(re.split(r"([0-9]+)", normalized(text))))


def book_fields(book, field, status_for):
    value = cell_value(book, field, status_for)
    values = value if isinstance(value, list) else [label(value)]
    if field == "title" and book.get("subtitle"):
        return [*values, book["subtitle"]]
    return values


def filter_value(field, text):
    value = text.strip()
    if field == "releaseYear" and value:
        if not re.fullmatch(r"\+?[0-9]+", value):
            raise ValueError("Enter a release year from 1 through 9999.")
        year = value.lstrip("+").lstrip("0")
        if not 1 <= len(year) <= 4:
            raise ValueError("Enter a release year from 1 through 9999.")
        return year
    return value


def filter_candidates(values):
    candidates = {}
    for value in values:
        trimmed = value.strip()
        key = normalized(trimmed)
        if key:
            first, count = candidates.get(key, (trimmed, 0))
            candidates[key] = (first, count + 1)
    return candidates


def matching_suggestions(candidates, text):
    text = text.strip()
    query = normalized(text)
    if not query:
        return []
    words = query.split()
    matches = []
    for key, (value, count) in candidates.items():
        if value == text:
            continue
        index = key.find(query)
        if key == query:
            rank = 0
        elif index == 0:
            rank = 1
        elif index > 0:
            rank = 3 if key[index - 1].isalnum() else 2
        elif len(words) > 1 and all(word in key for word in words):
            rank = 4
        else:
            continue
        matches.append((rank, -count, natural_key(value), value))
    return [value for _, _, _, value in sorted(matches)[:6]]


def purchase_date(value):
    if not value:
        return None
    try:
        if len(value) == 10:
            return datetime.combine(date.fromisoformat(value), time(), timezone.utc)
        timestamp = datetime.fromisoformat(value)
        return timestamp if timestamp.tzinfo is not None else None
    except ValueError:
        return None


def browse_books(books, query, filters, sort_field, reverse, status_for):
    query = normalized(query.strip())
    try:
        active_filters = [(key, normalized(filter_value(key, value))) for key, value in filters.items() if value.strip()]
    except ValueError:
        return []
    searchable_fields = ("title", "subtitle", "authors", "narrators", "series", "asin", "tags")
    with_value, without_value = [], []
    for book in books:
        if query and not any(query in normalized(label(book.get(key))) for key in searchable_fields):
            continue
        for field, needle in active_filters:
            values = book_fields(book, field, status_for)
            if not any(needle == normalized(item) if field in {"status", "releaseYear", "access", "listeningProgress", "tags"}
                       else needle in normalized(item) for item in values):
                break
        else:
            value = cell_value(book, sort_field, status_for)
            if sort_field == "purchaseDate":
                value = purchase_date(value)
            if value is None or value == "" or value == []:
                without_value.append(book)
                continue
            if sort_field not in {"durationSeconds", "purchaseDate"}:
                value = natural_key(value[0] if isinstance(value, list) else label(value))
            with_value.append((value, book))
    def title_key(book):
        return (natural_key(label(book.get("title"))), label(book.get("asin")))
    with_value.sort(key=lambda item: title_key(item[1]))
    with_value.sort(key=lambda item: item[0], reverse=reverse)
    return [book for _, book in with_value] + sorted(without_value, key=title_key)


def export_data(books, extension, *, wishlist=False):
    if extension == ".json":
        titles = [{key: value for key, value in book.items() if value is not None and not key.startswith("_")} for book in books]
        return (json.dumps(titles, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    columns = EXPORT_COLUMNS if wishlist else EXPORT_COLUMNS + LIBRARY_ONLY_COLUMNS
    headers = [title for title, _ in columns]
    if extension == ".xlsx":
        rows = ((_spreadsheet_value(book.get(key)) for _, key in columns) for book in books)
        return workbook_data(headers, rows, title="Wish List" if wishlist else "Library")
    if extension not in {".csv", ".tsv"}:
        raise ValueError(extension)
    output = io.StringIO(newline="")
    writer = csv.writer(output, delimiter="," if extension == ".csv" else "\t")
    writer.writerow(headers)
    writer.writerows([label(book.get(key)) for _, key in columns] for book in books)
    return output.getvalue().encode("utf-8")


def _spreadsheet_value(value):
    return value if value is None or isinstance(value, (str, int, float, bool)) else label(value)


def export_dialog(parent, books, *, wishlist=False, title=None, extension=None):
    formats = [(suffix, label) for suffix, label in EXPORT_FORMATS if extension is None or extension == suffix]
    if not formats:
        raise ValueError("Choose JSON, CSV, TSV, or Excel for export.")
    choices = [suffix for suffix, _label in formats]
    filenames = "|".join(f"{label} (*{suffix})|*{suffix}" for suffix, label in formats)
    name = ("DownAudible Wish List" if wishlist else "DownAudible Library") + (extension or "")
    with wx.FileDialog(parent, title or "Export Library", defaultFile=name, wildcard=filenames,
                       style=wx.FD_SAVE | wx.FD_OVERWRITE_PROMPT) as dialog:
        if dialog.ShowModal() != wx.ID_OK:
            return
        path = Path(dialog.GetPath())
        if path.suffix.lower() not in choices:
            path = path.with_suffix(choices[dialog.GetFilterIndex()])
        try:
            write_atomic(path, export_data(books, path.suffix.lower(), wishlist=wishlist))
        except OSError:
            show_error(parent, AudibleError("fileAccess"))
        except ValueError as error:
            wx.MessageBox(str(error), "Could Not Export", wx.OK | wx.ICON_ERROR, parent)


def selected_rows(control):
    index = control.GetFirstSelected()
    while index != wx.NOT_FOUND:
        yield index
        index = control.GetNextSelected(index)


class BookList(wx.ListCtrl):
    def __init__(self, parent, *, name="Audiobooks", columns=COLUMNS, select_all_action=None):
        super().__init__(parent, style=wx.LC_REPORT | wx.LC_HRULES | wx.BORDER_SUNKEN, name=name)
        if wx.Platform == "__WXMSW__":
            self.SetLabel(name)
        self.columns = columns
        self.rows = []
        self._cells = []
        self.select_all_action = select_all_action or self.select_all
        self.Bind(wx.EVT_CHAR_HOOK, self.on_key)
        for index, (title, _, width) in enumerate(columns):
            self.InsertColumn(index, title, width=width)

    def set_books(self, books, status_for):
        rows = list(books)
        keys = [book_identity(book) for book in rows]
        cells = [tuple(display_cell(book, field, status_for) for _, field, _ in self.columns) for book in rows]
        if keys == [book_identity(book) for book in self.rows]:
            self.rows = rows
            for index, (previous, current) in enumerate(zip(self._cells, cells, strict=True)):
                if previous != current:
                    for column, (before, after) in enumerate(zip(previous, current, strict=True)):
                        if before != after:
                            self.SetItem(index, column, after)
            self._cells = cells
            return
        selected = {book_identity(book) for book in self.selected_books()}
        original = self.GetFocusedItem()
        focused = book_identity(self.rows[original]) if 0 <= original < len(self.rows) else None
        self.Freeze()
        try:
            self.DeleteAllItems()
            self.rows, self._cells = rows, cells
            for index, (key, texts) in enumerate(zip(keys, cells, strict=True)):
                self.InsertItem(index, texts[0])
                for column, value in enumerate(texts[1:], start=1):
                    self.SetItem(index, column, value)
                if key in selected:
                    self.Select(index)
                if key == focused:
                    self.Focus(index)
        finally:
            self.Thaw()

    def selected_books(self):
        return [self.rows[index] for index in selected_rows(self) if index < len(self.rows)]

    def focus_result(self, _event=None):
        if not self.GetItemCount():
            return
        index = self.GetFocusedItem()
        if index == wx.NOT_FOUND:
            index = max(self.GetFirstSelected(), 0)
        self.SetFocus()
        self.Focus(index)
        if self.GetSelectedItemCount() == 0:
            self.Select(index)
        self.EnsureVisible(index)

    def on_key(self, event):
        if event.GetModifiers() == wx.MOD_CMD and event.GetKeyCode() == ord("A"):
            self.select_all_action()
        else:
            event.Skip()

    def select_all(self):
        self.Freeze()
        try:
            for index in range(self.GetItemCount()):
                self.Select(index)
        finally:
            self.Thaw()


class LibraryFilterDialog(wx.Dialog):
    def __init__(self, parent, field, caption, current="", values=()):
        super().__init__(parent, title=f"Filter by {caption}")
        self.field = field
        self.candidates = filter_candidates(values)
        self.value = None
        box = wx.BoxSizer(wx.VERTICAL)
        prompt = f"{caption} (1–9999)" if field == "releaseYear" else f"{caption} contains"
        box.Add(wx.StaticText(self, label=prompt), 0, wx.LEFT | wx.RIGHT | wx.TOP, self.FromDIP(12))
        self.condition = wx.TextCtrl(self, value=current, name=caption, style=wx.TE_PROCESS_ENTER)
        accessible_name(self.condition, prompt)
        box.Add(self.condition, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        suggested = wx.BoxSizer(wx.VERTICAL)
        suggested.Add(wx.StaticText(self, label="Suggestions"), 0, wx.BOTTOM, self.FromDIP(6))
        self.suggestions = wx.ListBox(self, style=wx.LB_SINGLE, size=self.FromDIP((-1, 112)))
        accessible_name(self.suggestions, "Filter suggestions")
        suggested.Add(self.suggestions, 0, wx.EXPAND)
        self.suggestion_group = box.Add(suggested, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(12))
        box.AddStretchSpacer()
        if current:
            box.Add(button(self, "Remove Filter", lambda: self.finish("")), 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(12))
        buttons = self.CreateSeparatedButtonSizer(wx.OK | wx.CANCEL)
        self.apply_button = self.FindWindowById(wx.ID_OK)
        self.apply_button.SetLabel("Apply Filter")
        self.apply_button.SetDefault()
        box.Add(buttons, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(12))
        self.SetSizer(box)
        minimum = box.CalcMin()
        self.SetClientSize((max(self.FromDIP(430), minimum.width), max(self.FromDIP(270), minimum.height)))
        self.condition.Bind(wx.EVT_TEXT, self.render_suggestions)
        self.condition.Bind(wx.EVT_CHAR_HOOK, self.text_keys)
        self.condition.Bind(wx.EVT_TEXT_ENTER, lambda event: self.apply())
        self.suggestions.Bind(wx.EVT_LISTBOX_DCLICK, lambda event: self.apply_suggestion())
        self.suggestions.Bind(wx.EVT_CHAR_HOOK, self.suggestion_keys)
        self.Bind(wx.EVT_BUTTON, lambda event: self.apply(), id=wx.ID_OK)
        self.render_suggestions()
        self.condition.SetFocus()

    def render_suggestions(self, _event=None):
        text = self.condition.GetValue()
        matches = matching_suggestions(self.candidates, text)
        self.suggestions.Set(matches)
        self.suggestion_group.Show(bool(matches))
        try:
            value = filter_value(self.field, text)
        except ValueError:
            value = ""
        self.apply_button.Enable(bool(value))
        self.Layout()

    def text_keys(self, event):
        key = event.GetKeyCode()
        if not event.HasModifiers() and key in {wx.WXK_UP, wx.WXK_DOWN} and self.suggestions.GetCount():
            self.suggestions.SetSelection(0 if key == wx.WXK_DOWN else self.suggestions.GetCount() - 1)
            self.suggestions.SetFocus()
        else:
            event.Skip()

    def suggestion_keys(self, event):
        if not event.HasModifiers() and event.GetKeyCode() in {wx.WXK_RETURN, wx.WXK_NUMPAD_ENTER}:
            self.apply_suggestion()
        else:
            event.Skip()

    def apply_suggestion(self):
        if selection := self.suggestions.GetStringSelection():
            self.finish(filter_value(self.field, selection))

    def apply(self):
        if self.suggestions.GetSelection() != wx.NOT_FOUND:
            self.apply_suggestion()
        elif self.apply_button.IsEnabled():
            self.finish(filter_value(self.field, self.condition.GetValue()))

    def finish(self, value):
        self.value = value
        self.EndModal(wx.ID_OK)


class LibraryPanel(wx.Panel):
    def __init__(self, parent, frame):
        super().__init__(parent, name="Library")
        self.frame = frame
        self.client = AudibleClient(frame.resource_dir, frame.data_dir, demo=frame.demo)
        self.catalogue = Catalogue(frame.data_dir / "Library Snapshots")
        self.all_accounts = False
        self.books = []
        self.filters = {}
        self.sort_field = "title"
        self.sort_reverse = False
        self._refresh_request = None
        self._windows = {}
        self._rendering = False
        self._missing_count = 0
        self._fetch_message = ""
        self._fetch_error = False
        if frame.demo and not self.accounts:
            frame.settings["audible_accounts"] = [
                {"id": "demo-account", "name": "Demo Account", "marketplace": "uk"},
                {"id": "demo-account-2", "name": "Demo Account 2", "marketplace": "us"},
            ]
            frame.settings["audible_account"] = "demo-account"
        self.signed_in = self.is_signed_in(self.active_account_id)
        self.restore_sort()

        top = wx.BoxSizer(wx.VERTICAL)
        row = wx.BoxSizer(wx.HORIZONTAL)
        self.account = wx.Choice(self, name="Active Audible account")
        self.account.Bind(wx.EVT_CHOICE, self.account_changed)
        row.Add(self.account, 0, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, 8)
        row.Add(button(self, "Accounts…", self.manage_accounts), 0, wx.RIGHT, 8)
        self.refresh_button = button(self, "Refresh Library", self.refresh)
        row.Add(self.refresh_button, 0, wx.RIGHT, 8)
        self.search = wx.SearchCtrl(self, name="Find in Library", style=wx.TE_PROCESS_ENTER)
        accessible_name(self.search, "Find in Library")
        self.search.ShowCancelButton(True)
        self.search.SetDescriptiveText("Find in Library")
        self.search.Bind(wx.EVT_TEXT, lambda event: self.render())
        self.search.Bind(wx.EVT_SEARCHCTRL_CANCEL_BTN, lambda event: self.search.Clear())
        self.search.Bind(wx.EVT_TEXT_ENTER, self.focus_results)
        self.account.SetToolTip("Browse one saved Audible account or all accounts together.")
        self.refresh_button.SetToolTip("Load the latest titles in the current library view.")
        self.search.SetToolTip("Search titles, authors, narrators, series, and ASINs.")
        row.Add(self.search, 1, wx.ALIGN_CENTER_VERTICAL)
        top.Add(row, 0, wx.EXPAND | wx.ALL, 8)
        actions = wx.BoxSizer(wx.HORIZONTAL)
        self.download_button = button(self, "Download Selected…", self.download_selection)
        self.missing_button = button(self, "Download Missing…", self.download_missing)
        self.sort_button = button(self, "Sort Library", self.show_sort)
        self.filter_button = button(self, "Filter Library", self.show_filter)
        self.actions_button = button(self, "Library Actions", self.show_actions)
        self.download_button.SetToolTip("Review what to save for the selected audiobooks.")
        self.missing_button.SetToolTip("Check for audiobooks without a complete saved or matched copy.")
        self.sort_button.SetToolTip("Choose how the audiobooks are ordered.")
        self.filter_button.SetToolTip("Narrow the library by metadata, tags, access, listening progress, or download status.")
        self.actions_button.SetToolTip("Open library status, matching, export, and other library commands.")
        for control in (self.download_button, self.missing_button, self.sort_button, self.filter_button, self.actions_button):
            actions.Add(control, 0, wx.RIGHT, 7)
        top.Add(actions, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)
        filter_row = wx.BoxSizer(wx.HORIZONTAL)
        self.filter_summary = wx.StaticText(self, style=wx.ST_NO_AUTORESIZE | wx.ST_ELLIPSIZE_END)
        filter_row.Add(self.filter_summary, 1, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, 8)
        self.clear_filter_button = button(self, "Clear Filters", self.clear_filters)
        filter_row.Add(self.clear_filter_button)
        self.filter_row = top.Add(filter_row, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)
        self.filter_row.Show(False)
        self.sign_in_panel = wx.Panel(self, name="Connect Audible account")
        welcome = wx.BoxSizer(wx.VERTICAL)
        heading = wx.StaticText(self.sign_in_panel, label="Your Audible Library")
        heading.SetFont(heading.GetFont().Scale(1.25).Bold())
        welcome.AddStretchSpacer()
        welcome.Add(heading, 0, wx.ALIGN_CENTER | wx.BOTTOM, 8)
        welcome.Add(wx.StaticText(self.sign_in_panel, label="Sign in to see your audiobooks and choose what to download."),
                    0, wx.ALIGN_CENTER | wx.BOTTOM, 16)
        self.connect_button = button(self.sign_in_panel, "Sign In…", self.reconnect)
        welcome.Add(self.connect_button, 0, wx.ALIGN_CENTER | wx.BOTTOM, 6)
        welcome.Add(button(self.sign_in_panel, "Import Account…", self.import_account), 0, wx.ALIGN_CENTER)
        welcome.AddStretchSpacer()
        self.sign_in_panel.SetSizer(welcome)
        top.Add(self.sign_in_panel, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, 8)
        self.load_error_panel = wx.Panel(self)
        load_error = wx.BoxSizer(wx.VERTICAL)
        heading = wx.StaticText(self.load_error_panel, label="Could Not Load Library")
        heading.SetFont(heading.GetFont().Bold())
        self.load_error = wx.StaticText(self.load_error_panel)
        self.retry_button = button(self.load_error_panel, "Retry", self.refresh)
        self.retry_button.SetToolTip("Try to load the active Audible account’s library again.")
        load_error.AddStretchSpacer()
        for control in (heading, self.load_error, self.retry_button):
            load_error.Add(control, 0, wx.ALIGN_CENTER | wx.ALL, self.FromDIP(8))
        load_error.AddStretchSpacer()
        self.load_error_panel.SetSizer(load_error)
        top.Add(self.load_error_panel, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, 8)
        self.list = BookList(self, name="Audible Library", select_all_action=self.select_all)
        self.list.Bind(wx.EVT_LIST_COL_CLICK, self.column_clicked)
        self.list.Bind(wx.EVT_LIST_ITEM_SELECTED, lambda event: self.update_status())
        self.list.Bind(wx.EVT_LIST_ITEM_DESELECTED, lambda event: self.update_status())
        self.list.Bind(wx.EVT_LIST_ITEM_ACTIVATED, self.activate_result)
        self.list.Bind(wx.EVT_CONTEXT_MENU, self.context_menu)
        if wx.Platform == "__WXMSW__":
            order = self.restore_columns()
            if order:
                self.list.SetColumnsOrder(order)
            self.list.Bind(wx.EVT_KILL_FOCUS, self.save_columns_on_focus)
        top.Add(self.list, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, 8)
        self.status = wx.StaticText(self, label=" ", name="Library status")
        top.Add(self.status, 0, wx.EXPAND | wx.ALL, 8)
        self.SetSizer(top)
        self.catalogue_timer = wx.Timer(self)
        self.Bind(wx.EVT_TIMER, lambda _event: self.refresh(all_accounts=True, background=True), self.catalogue_timer)
        self.update_accounts()
        if frame.demo:
            for index, account in enumerate(self.accounts):
                books = demo_books()
                self.catalogue.record(account["id"], books[:3] if index else books, self.library_options(), persist=False)
        self.show_cached_catalogue()
        self.configure_background_refresh()
        if not frame.demo:
            wx.CallAfter(self.refresh)

    @property
    def accounts(self):
        return self.frame.settings.get("audible_accounts", [])

    @property
    def active_account_id(self):
        return self.frame.settings.get("audible_account")

    @property
    def active_account(self):
        return next((account for account in self.accounts if account["id"] == self.active_account_id), None)

    @property
    def sign_in_marketplace(self):
        if account := self.active_account:
            return account["marketplace"]
        return self.frame.settings.get("audible_marketplace", "uk")

    @property
    def browsing(self):
        return self.signed_in or bool(self.books) or (self.all_accounts and bool(self.accounts))

    def book_account(self, book):
        owner = profile_id(book, self.active_account_id)
        return next((account for account in self.accounts if account["id"] == owner), None)

    def displayed_accounts(self):
        return self.accounts if self.all_accounts else [self.active_account] if self.active_account else []

    def show_cached_catalogue(self):
        tags = self.frame.settings.get("library_tags", {})
        self.books = [tagged_book(book, account, tags) for account in self.displayed_accounts()
                      for book in (self.catalogue.get(account["id"]) or {}).get("books", ())]
        self.update_visibility()
        self.render()

    def configure_background_refresh(self):
        enabled = self.frame.settings.get("background_library_refresh") is True and not self.frame.demo
        if enabled and not self.catalogue_timer.IsRunning():
            self.catalogue_timer.Start(30 * 60 * 1000)
        elif not enabled:
            self.catalogue_timer.Stop()

    def is_signed_in(self, account_id):
        if not account_id:
            return False
        try:
            return self.client.has_session(account_id)
        except AudibleError:
            return False

    def update_accounts(self):
        accounts = self.accounts
        labels = [item["name"] for item in accounts]
        self.all_accounts = self.all_accounts and len(accounts) > 1
        self.account.Set([*labels, "All Accounts"] if len(accounts) > 1 else labels or [NO_ACCOUNTS])
        width = min(self.account.GetBestSize().width, self.FromDIP(185))
        self.account.SetMinSize((width, -1))
        index = len(accounts) if self.all_accounts else next(
            (index for index, item in enumerate(accounts) if item["id"] == self.active_account_id), 0)
        self.account.SetSelection(index)
        self.account.Enable(bool(accounts))
        accessible_name(self.account, "Library account view" if accounts else NO_ACCOUNTS)
        account_column = len(COLUMNS) - 1
        self.list.SetColumnWidth(account_column, self.FromDIP(COLUMNS[-1][2]) if self.all_accounts else 0)
        if wx.Platform == "__WXMSW__":
            order = self.restore_columns() or list(range(len(COLUMNS)))
            if self.all_accounts:
                order.remove(account_column)
                order.insert(order.index(0) + 1, account_column)
            self.list.SetColumnsOrder(order)
        self.Layout()

    def account_changed(self, _event):
        index = self.account.GetSelection()
        if index == len(self.accounts) and len(self.accounts) > 1:
            self.all_accounts = True
            self._fetch_error = False
            self._fetch_message = ""
            self.restore_sort()
            self.update_accounts()
            self.show_cached_catalogue()
            if any(self.catalogue.get(account["id"]) is None and self.is_signed_in(account["id"]) for account in self.accounts):
                self.refresh(all_accounts=True)
            return
        if 0 <= index < len(self.accounts):
            try:
                self.switch_account(self.accounts[index]["id"])
            except AudibleError as error:
                self.update_accounts()
                show_error(self, error)

    def save_account(self, account_id, name, marketplace, session, *, previous_registration=None):
        original = next((item for item in self.accounts if item["id"] == account_id), {})
        source_id = None
        if previous_registration is not None:
            if not self.can_remove_accounts():
                raise AudibleError("accountInUse")
            source_id, _ = previous_registration
            if not any(item["id"] == source_id and item["marketplace"] == marketplace for item in self.accounts):
                raise AudibleError("accountVerification")
        readable_name = name or MARKETPLACES.get(marketplace, marketplace)
        replacement = dict(original, id=account_id, name=readable_name, marketplace=marketplace)
        replacement.pop("widevine_enabled", None)
        accounts = [replacement if item["id"] == account_id else item for item in self.accounts]
        if replacement not in accounts:
            accounts.append(replacement)
        with self.client.session_change(account_id, session, previous_registration=previous_registration):
            change = nullcontext()
            if source_id != account_id:
                cdm = self.client.widevine_cdm(source_id) if source_id is not None else None
                change = self.client.widevine_change(account_id, cdm)
            with change:
                self._persist_accounts(accounts, account_id)
        if original and source_id != account_id:
            self.clear_catalogue(account_id)
        self._reload_account()

    def widevine_enabled_for(self, account_id):
        return any(account["id"] == account_id and account.get("widevine_enabled") is True
                   for account in self.accounts)

    def set_widevine(self, account_id, enabled, cdm=None):
        if not self.can_remove_accounts():
            raise AudibleError("accountInUse")
        pending = [dict(account, widevine_enabled=enabled) if account["id"] == account_id else account
                   for account in self.accounts]
        change = self.client.widevine_change(account_id, cdm) if cdm is not None else nullcontext()
        with change:
            self._persist_accounts(pending, self.active_account_id)

    def rename_account(self, account_id, name):
        pending = [dict(account, name=name) if account["id"] == account_id else account for account in self.accounts]
        self._persist_accounts(pending, self.active_account_id)
        self.update_accounts()
        self.show_cached_catalogue()
        if tools := self._windows.get("tools"):
            tools.refresh_account_name()
        if status := self._windows.get("status"):
            status.render()

    def can_remove_accounts(self):
        return not getattr(getattr(self.frame, "queue", None), "pending", False)

    def _persist_accounts(self, accounts, active_account, *, removed_account=None):
        settings = self.frame.settings
        updated = {"audible_accounts": accounts, "audible_account": active_account}
        active = next((account for account in accounts if account["id"] == active_account), None)
        if active is None:
            active = next((account for account in settings.get("audible_accounts", [])
                           if account["id"] == settings.get("audible_account")), None)
        if active and active.get("marketplace") in MARKETPLACES:
            updated["audible_marketplace"] = active["marketplace"]
        if removed_account is not None:
            for key in ("matches", "match_folders", "automatic_matches", "library_sort", "library_tags", "saved_library_views"):
                if removed_account in settings.get(key, {}):
                    updated[key] = {key_id: value for key_id, value in settings[key].items() if key_id != removed_account}
        previous = {key: settings[key] for key in updated if key in settings}
        settings.update(updated)
        try:
            self.frame.save_settings()
        except OSError:
            for key in updated:
                settings.pop(key, None)
            settings.update(previous)
            raise AudibleError("fileAccess") from None

    def switch_account(self, account_id):
        if self.active_account_id == account_id and not self.all_accounts:
            return
        if self.active_account_id != account_id:
            self._persist_accounts(self.accounts, account_id)
        self.all_accounts = False
        self._reload_account()

    def _reload_account(self):
        if self._refresh_request is not None:
            self._refresh_request.set()
            self._refresh_request = None
        for key in ("tools", "status"):
            if window := self._windows.get(key):
                window.Close()
        self.filters.clear()
        self.search.ChangeValue("")
        self.signed_in = self.is_signed_in(self.active_account_id)
        self._fetch_error = False
        self._fetch_message = ""
        self.restore_sort()
        self.update_accounts()
        self.show_cached_catalogue()
        if accounts_window := self._windows.get("accounts"):
            accounts_window.refresh()
        self.refresh()

    def sign_out(self, account_id):
        if not self.can_remove_accounts():
            raise AudibleError("accountInUse")
        pending = [dict(account, widevine_enabled=False) if account["id"] == account_id else account
                   for account in self.accounts]
        with self.client.session_change(account_id, None), self.client.widevine_change(account_id, None):
            self._persist_accounts(pending, self.active_account_id)
        self.clear_catalogue(account_id)
        if account_id == self.active_account_id:
            self._reload_account()
        elif self.all_accounts:
            self.show_cached_catalogue()

    def remove_account(self, account_id):
        if not self.can_remove_accounts():
            raise AudibleError("accountInUse")
        active_account = self.active_account_id
        remaining = [item for item in self.accounts if item["id"] != account_id]
        removing_active = account_id == active_account
        if removing_active:
            active_account = remaining[0]["id"] if remaining else None
        with self.client.session_change(account_id, None), self.client.widevine_change(account_id, None):
            self._persist_accounts(remaining, active_account, removed_account=account_id)
        self.clear_catalogue(account_id)
        if removing_active:
            self._reload_account()
        else:
            self.update_accounts()
            self.show_cached_catalogue()

    def clear_catalogue(self, account_id):
        if not hasattr(self, "catalogue"):
            return
        try:
            self.catalogue.remove(account_id)
        except OSError:
            self.frame.error("The saved library could not be removed from the local data folder.")

    def restore_sort(self):
        setting = self.frame.settings.get("library_sort", {}).get(self.library_view_scope(), {})
        supported = {field for _, field, _ in COLUMNS}
        field = setting.get("field")
        self.sort_field = field if isinstance(field, str) and field in supported else "title"
        self.sort_reverse = setting.get("reverse") is True

    def status_for(self, book):
        return self.frame.status_for(book)

    def library_options(self, *, filter_purchases=False):
        options = dict(self.frame.settings.get("api", {}))
        if filter_purchases:
            options = purchase_date_options(options)
        else:
            options.pop("purchaseStart", None)
            options.pop("purchaseEnd", None)
        options["timeout"] = self.frame.settings.get("timeout", 45)
        return options

    def refresh(self, *, all_accounts=False, background=False):
        if background and self.frame.queue.pending:
            return
        if self._refresh_request is not None:
            if background:
                return
            self._refresh_request.set()
        self._refresh_request = None
        self.refresh_button.Enable(True)
        self.signed_in = self.is_signed_in(self.active_account_id)
        self._fetch_error = False
        all_accounts = all_accounts or self.all_accounts
        accounts = [account for account in (self.accounts if all_accounts else self.displayed_accounts())
                    if self.is_signed_in(account["id"])]
        if not accounts:
            self.show_cached_catalogue()
            return

        try:
            options = self.library_options(filter_purchases=True)
        except ValueError as error:
            self.show_fetch_error(error)
            return

        self._refresh_request = request = threading.Event()
        self.refresh_button.Enable(False)
        self._fetch_message = "Refreshing all Audible accounts…" if all_accounts else "Loading Audible library…"
        self.update_visibility()
        self.update_status()

        def work():
            loaded, failures = [], []
            cooldowns = self.frame.runner.refusals
            for account in accounts:
                identifier = account["id"]
                try:
                    cooldowns.check(identifier, lambda code: str(AudibleError(code)))
                    session = self.client.session(identifier)
                    books = self.client.run("library", session=session, options=options, cancel=request)
                    loaded.append((identifier, session, books))
                except RetryAfter as error:
                    failures.append(f"{account['name']}: {error.detail(automatic=False)}")
                except AudibleError as error:
                    if request.is_set():
                        break
                    detail = str(error)
                    try:
                        cooldowns.record(identifier, error.code, detail)
                    except RetryAfter as refusal:
                        detail = refusal.detail(automatic=False)
                    failures.append(f"{account['name']}: {detail}")
            return loaded, failures

        def complete(result):
            loaded, failures = result
            current = {item["id"]: item["name"] for item in self.accounts}
            for identifier, session, books in loaded:
                if identifier not in current:
                    continue
                try:
                    if self.client.session(identifier) == session:
                        self.catalogue.record(identifier, books, options, persist=not self.frame.demo)
                except AudibleError:
                    continue
                except OSError:
                    failures.append(f"{current[identifier]}: Could not save the offline library.")
            self._fetch_message = ""
            self.show_cached_catalogue()
            if failures:
                message = failures[0] if len(failures) == 1 else f"Could not refresh {len(failures)} Audible accounts."
                if self.books:
                    message = f"Showing available saved titles. {message}"
                self.show_fetch_error(message)
            if loaded:
                self.frame.scan_archive()

        def done():
            self._refresh_request = None
            self.refresh_button.Enable(True)

        run_async(self, work, complete, failure=self.show_fetch_error, done=done, cancel=request)

    def show_fetch_error(self, error):
        self._fetch_error = True
        self._fetch_message = str(error)
        self.update_visibility()
        self.update_status()

    def render(self):
        status = {book_identity(book, self.active_account_id): self.status_for(book) for book in self.books}

        def cached_status(book):
            return status[book_identity(book, self.active_account_id)]

        rows = browse_books(self.books, self.search.GetValue(), self.filters, self.sort_field, self.sort_reverse, cached_status)
        transfers = self.frame.library_transfers()
        owners = self.signed_in_displayed_accounts()
        self._missing_count = sum(self.eligible_as_missing(book, cached_status, transfers, owners) for book in self.books)
        self._rendering = True
        try:
            self.list.set_books(rows, lambda book: self.display_status(book, cached_status(book)))
        finally:
            self._rendering = False
        for column, (title, field, _width) in enumerate(COLUMNS):
            item = self.list.GetColumn(column)
            direction = " ↓" if self.sort_reverse else " ↑"
            heading = f"{title}{direction}" if field == self.sort_field else title
            if item.GetText() != heading:
                item.SetText(heading)
                self.list.SetColumn(column, item)
        self.update_filter_summary()
        if status_window := self._windows.get("status"):
            status_window.render()
        if accounts_window := self._windows.get("accounts"):
            accounts_window.update_actions()
        self.update_status()

    def update_visibility(self):
        for control in (self.search, self.refresh_button, self.sort_button, self.filter_button,
                        self.actions_button, self.download_button, self.missing_button):
            control.Show(self.browsing)
        failed = self.browsing and self._fetch_error and not self.books
        self.list.Show(self.browsing and not failed)
        self.load_error_panel.Show(failed)
        if failed:
            self.load_error.SetLabel(self._fetch_message)
            self.load_error.Wrap(max(self.FromDIP(160), self.GetClientSize().width - self.FromDIP(40)))
            self.retry_button.SetFocus()
        self.sign_in_panel.Show(not self.browsing)
        if not self.browsing:
            self.connect_button.SetFocus()
        self.update_filter_summary()
        self.Layout()

    def update_filter_summary(self):
        if self.filters:
            predicates = [f'{title} “{self.filters[field]}”' for title, field in FILTER_FIELDS.items()
                          if field in self.filters]
            summary = "Active filters: " + ", ".join(predicates)
            self.filter_summary.SetLabel(summary)
            self.filter_summary.SetToolTip(summary)
            self.filter_button.SetLabel(f"Filter Library ({len(self.filters)})")
        else:
            self.filter_button.SetLabel("Filter Library")
        show = self.browsing and bool(self.filters)
        if self.filter_row.IsShown() != show:
            self.filter_row.Show(show)
            self.Layout()

    def update_status(self):
        if self._rendering:
            return
        selected = self.selected_books()
        total = len(self.books)
        shown = len(self.list.rows)
        total_label = f"{shown} of {total}" if shown != total else str(total)
        status = self._fetch_message or f"{total_label} audiobooks   |   {len(selected)} selected   |   {self._missing_count} to download"
        if not self._fetch_message and not self.all_accounts and self.catalogue.get(self.active_account_id):
            status += f"   |   {refresh_label(self.catalogue.get(self.active_account_id))}"
        self.status.SetLabel(status)
        show_status = self.browsing and not self.load_error_panel.IsShown()
        if self.status.Show(show_status and (bool(self._fetch_message) or self.frame.settings.get("show_status", True))):
            self.Layout()
        queue = getattr(self.frame, "queue", None)
        active = queue is not None and queue.pending
        adding = active and self.frame.can_add_downloads()
        caption = "Add Selected to Queue…" if adding else "Download Selected…"
        if self.download_button.GetLabel() != caption:
            self.download_button.SetLabel(caption)
            self.download_button.SetToolTip("Add books using the current batch’s options." if adding else
                                            "Review what to save for the selected audiobooks.")
            self.Layout()
        eligible = self.frame.download_queue_additions(selected) if adding else self.frame.downloadable_books(selected)
        self.download_button.Enable(bool(eligible) and (adding or not active))
        self.missing_button.Enable(self._missing_count > 0 and not active)

    def focus_search(self):
        if self.browsing:
            self.search.SetFocus()
            self.search.SelectAll()
        else:
            self.connect_button.SetFocus()

    def focus_workspace(self):
        if self.load_error_panel.IsShown():
            self.retry_button.SetFocus()
        else:
            (self.list if self.browsing else self.connect_button).SetFocus()

    def focus_results(self, _event=None):
        self.list.focus_result()
        self.update_status()

    def activate_result(self, event):
        index = event.GetIndex()
        if 0 <= index < len(self.list.rows) and self.list.GetSelectedItemCount() == 0:
            self.list.Select(index)
        self.download_selection()

    def selected_books(self):
        return self.list.selected_books()

    def visible_books(self):
        return list(self.list.rows)

    def select_all(self):
        self._rendering = True
        try:
            self.list.select_all()
        finally:
            self._rendering = False
        self.update_status()

    def missing_books(self):
        transfers = self.frame.library_transfers()
        owners = self.signed_in_displayed_accounts()
        return [book for book in self.books if self.eligible_as_missing(book, self.status_for, transfers, owners)]

    def signed_in_displayed_accounts(self):
        return {account["id"] for account in self.displayed_accounts() if self.is_signed_in(account["id"])}

    def eligible_as_missing(self, book, status_for, transfers, owners):
        owner = profile_id(book, self.active_account_id)
        return ((owner, book["asin"]) not in transfers and owner in owners and bool(book.get("isDownloadable"))
                and status_for(book) in {"Not downloaded", "Incomplete", "Files missing"})

    def download_selection(self):
        books = self.selected_books()
        if self.frame.can_add_downloads():
            self.frame.review_add(books)
        else:
            self.frame.review_download(books)

    def download_missing(self):
        self.frame.request_missing_downloads()

    def display_status(self, book, status):
        if status != "Files missing":
            return status
        missing = sorted({path.name for path in self.frame.missing_output_files(book)}, key=str.casefold)
        if not missing:
            return status
        count = len(missing)
        noun = "file" if count == 1 else "files"
        return f"{count} {noun} missing: {', '.join(missing)}"

    def set_sort(self, key, reverse=False):
        self.sort_field, self.sort_reverse = key, reverse
        self.frame.settings.setdefault("library_sort", {})[self.library_view_scope()] = {"field": key, "reverse": reverse}
        self.frame.save_settings()
        self.render()

    def reverse_sort(self):
        if self.browsing:
            self.set_sort(self.sort_field, not self.sort_reverse)

    def column_clicked(self, event):
        column = event.GetColumn()
        if 0 <= column < len(COLUMNS):
            field = COLUMNS[column][1]
            self.set_sort(field, not self.sort_reverse if field == self.sort_field else False)

    def save_columns(self):
        if wx.Platform != "__WXMSW__":
            return False
        order = list(self.list.GetColumnsOrder())
        if len(order) != len(COLUMNS):
            return False
        fields = [COLUMNS[index][1] for index in order]
        if fields == self.frame.settings.get("library_columns", []):
            return False
        self.frame.settings["library_columns"] = fields
        return True

    def restore_columns(self):
        order = self.frame.settings.get("library_columns", [])
        if not isinstance(order, list):
            return []
        if all(isinstance(index, int) for index in order) and sorted(order) == list(range(len(LEGACY_COLUMN_FIELDS))):
            if order == list(range(len(LEGACY_COLUMN_FIELDS))):
                return []
            order = [LEGACY_COLUMN_FIELDS[index] for index in order]
        fields = [field for _title, field, _width in COLUMNS]
        if not all(isinstance(field, str) for field in order):
            return []
        if set(order) == set(fields[:-1]):
            order = [*order, fields[-1]]
        if sorted(order) != sorted(fields):
            return []
        return [fields.index(field) for field in order]

    def save_columns_on_focus(self, event):
        event.Skip()
        if not self.frame.IsBeingDeleted() and self.save_columns():
            self.frame.save_settings()

    def show_sort(self):
        if not self.browsing:
            return
        menu = wx.Menu()
        try:
            for title, field, _width in COLUMNS:
                item = menu.AppendCheckItem(wx.ID_ANY, title)
                item.Check(field == self.sort_field)
                menu.Bind(wx.EVT_MENU, lambda event, key=field: self.set_sort(key, self.sort_reverse), item)
            menu.AppendSeparator()
            orders = {
                "purchaseDate": ("Oldest First", "Newest First"),
                "releaseYear": ("Oldest First", "Newest First"),
                "durationSeconds": ("Shortest First", "Longest First"),
            }.get(self.sort_field, ("A to Z", "Z to A"))
            for direction, title in enumerate(orders):
                item = menu.AppendCheckItem(wx.ID_ANY, title)
                item.Check(bool(direction) == self.sort_reverse)
                menu.Bind(wx.EVT_MENU, lambda event, reverse=bool(direction): self.set_sort(self.sort_field, reverse), item)
            self._menu_action(menu, "Reverse Sort Order", self.reverse_sort)
            self.sort_button.PopupMenu(menu)
        finally:
            menu.Destroy()

    def show_filter(self):
        if not self.browsing:
            return
        menu = wx.Menu()
        try:
            for title, field in FILTER_FIELDS.items():
                if field in {"status", "access", "listeningProgress"}:
                    continue
                current = self.filters.get(field)
                item = menu.Append(wx.ID_ANY, f"{title} ({current})…" if current else f"{title}…")
                menu.Bind(wx.EVT_MENU, lambda event, key=field, caption=title: self.edit_filter(key, caption), item)
            for caption, field, values in (("Download Status", "status", STATUS_ORDER), ("Access", "access", ACCESS),
                                           ("Listening Progress", "listeningProgress", PROGRESS)):
                options = wx.Menu()
                for value in ("", *values):
                    item = options.AppendCheckItem(wx.ID_ANY, value or f"Any {caption}")
                    item.Check(self.filters.get(field, "") == value)
                    options.Bind(wx.EVT_MENU, lambda event, key=field, selected=value: self.set_filter(key, selected), item)
                menu.AppendSubMenu(options, caption)
            menu.AppendSeparator()
            self._menu_action(menu, "Clear Filters", self.clear_filters, bool(self.filters))
            self.filter_button.PopupMenu(menu)
        finally:
            menu.Destroy()

    def edit_filter(self, field, caption):
        values = []
        if self.frame.settings.get("filter_suggestions", True):
            other_filters = {key: value for key, value in self.filters.items() if key != field}
            matching = browse_books(self.books, self.search.GetValue(), other_filters, "title", False, self.status_for)
            values = [value for book in matching for value in book_fields(book, field, self.status_for)]
        with LibraryFilterDialog(self, field, caption, self.filters.get(field, ""), values) as dialog:
            if dialog.ShowModal() == wx.ID_OK and dialog.value is not None:
                self.set_filter(field, dialog.value)

    def set_filter(self, field, value):
        if value:
            self.filters[field] = value
        else:
            self.filters.pop(field, None)
        self.render()

    def clear_filters(self):
        if wx.Window.FindFocus() is self.clear_filter_button:
            self.filter_button.SetFocus()
        self.filters.clear()
        self.render()

    def export_books(self, visible=False, extension=None):
        books = self.visible_books() if visible else self.books
        if books:
            export_dialog(self, books, title="Export Visible Results" if visible else "Export Library", extension=extension)

    def export_to_goodreads(self, books=None):
        from .reading_views import GoodreadsDialog

        books = self.visible_books() if books is None else books
        if books:
            with GoodreadsDialog(self.frame, books) as dialog:
                dialog.ShowModal()

    def library_view_scope(self):
        return "all_accounts" if self.all_accounts else self.active_account_id or ""

    def saved_views(self):
        saved = self.frame.settings.get("saved_library_views")
        current = saved.get(self.library_view_scope()) if isinstance(saved, dict) else None
        return dict(current) if isinstance(current, dict) else {}

    def save_views(self, updated):
        scopes = self.frame.settings.get("saved_library_views")
        scopes = dict(scopes) if isinstance(scopes, dict) else {}
        scopes[self.library_view_scope()] = updated
        self.save_organisation("saved_library_views", scopes)

    def populate_saved_views(self, menu):
        saved = self.saved_views()
        for name in sorted(saved, key=str.casefold):
            self._menu_action(menu, name.replace("&", "&&"), lambda selected=name: self.apply_saved_view(selected), self.browsing)
        if saved:
            menu.AppendSeparator()
        self._menu_action(menu, "Save Current View…", self.save_current_view, self.browsing)
        self._menu_action(menu, "Manage Saved Views…", self.manage_saved_views, bool(saved))

    def save_current_view(self):
        saved = self.saved_views()
        name = self.prompt_view_name("Save Current View", saved)
        if name:
            saved[name] = {"search": self.search.GetValue(), "filters": dict(self.filters),
                           "sort": self.sort_field, "reverse": self.sort_reverse}
            self.save_views(saved)

    def prompt_view_name(self, title, saved, current=""):
        with wx.TextEntryDialog(self, "Enter a name for this library view.", title, value=current) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return ""
            name = " ".join(dialog.GetValue().split())
        if not name or len(name) > 72 or any(key != current and key.casefold() == name.casefold() for key in saved):
            raise ValueError("Enter a unique view name with up to 72 characters.")
        return name

    def apply_saved_view(self, name):
        view = self.saved_views().get(name)
        if not isinstance(view, dict):
            return
        self.search.ChangeValue(view.get("search") if isinstance(view.get("search"), str) else "")
        values = view.get("filters")
        self.filters = {key: value for key, value in values.items() if key in FILTER_FIELDS.values() and isinstance(value, str)} if isinstance(values, dict) else {}
        sort = view.get("sort")
        self.set_sort(sort if sort in {field for _, field, _ in COLUMNS} else "title", view.get("reverse") is True)

    def manage_saved_views(self):
        saved = self.saved_views()
        if not saved:
            return
        with wx.SingleChoiceDialog(self, "Choose a saved view.", "Manage Saved Views", sorted(saved, key=str.casefold)) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return
            selected = dialog.GetStringSelection()
        with wx.MessageDialog(self, f"Choose how to manage “{selected}”.", "Manage Saved Views",
                              wx.YES_NO | wx.CANCEL | wx.CANCEL_DEFAULT) as actions:
            actions.SetYesNoLabels("Rename…", "Delete")
            choice = actions.ShowModal()
        if choice == wx.ID_CANCEL:
            return
        if choice == wx.ID_YES:
            name = self.prompt_view_name("Rename Saved View", saved, selected)
            if not name or name == selected:
                return
            saved[name] = saved[selected]
        del saved[selected]
        self.save_views(saved)

    def save_organisation(self, key, updated):
        previous = self.frame.settings.get(key, {})
        self.frame.settings[key] = updated
        try:
            self.frame.save_settings()
        except OSError:
            self.frame.settings[key] = previous
            raise

    def edit_tags(self, books):
        if not books:
            return
        current = ", ".join(books[0].get("tags", [])) if len(books) == 1 else ""
        with wx.TextEntryDialog(self, "Enter comma-separated tags for the selected books. Clear the field to remove tags.",
                                "Tags", value=current) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return
            tags = parse_tags(dialog.GetValue())
        previous = self.frame.settings.get("library_tags", {})
        updated = {owner: dict(entries) for owner, entries in previous.items()}
        for book in books:
            owner, asin = book_identity(book, self.active_account_id)
            entries = updated.setdefault(owner, {})
            if tags:
                entries[asin] = tags
            else:
                entries.pop(asin, None)
        self.save_organisation("library_tags", updated)
        self.books = [dict(book, tags=updated.get(profile_id(book, self.active_account_id), {}).get(book["asin"], []))
                      for book in self.books]
        self.render()

    def show_library_changes(self):
        with self.library_changes_dialog() as dialog:
            dialog.ShowModal()

    def library_changes_dialog(self):
        dialog = wx.Dialog(self, title="Library Changes", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        layout = wx.BoxSizer(wx.VERTICAL)
        rows = report_list(dialog, "Library changes", (("Account", 155), ("Last successful refresh", 175),
                                                      ("Change", 135), ("Title", 220)), fill=3)
        for account in self.accounts:
            entry = self.catalogue.get(account["id"])
            changes = entry.get("changes", []) if entry else []
            for change in changes or [{"change": "No changes" if entry else "Awaiting refresh", "title": ""}]:
                index = rows.InsertItem(rows.GetItemCount(), account["name"])
                for column, text in enumerate((refresh_label(entry, ""), change["change"], change["title"]), 1):
                    rows.SetItem(index, column, text)
        layout.Add(rows, 1, wx.EXPAND | wx.ALL, dialog.FromDIP(12))
        close = button(dialog, "Close", lambda: dialog.EndModal(wx.ID_CLOSE))
        dialog.SetEscapeId(close.GetId())
        layout.Add(close, 0, wx.ALIGN_RIGHT | wx.LEFT | wx.RIGHT | wx.BOTTOM, dialog.FromDIP(12))
        dialog.SetSizer(layout)
        dialog.SetSize(dialog.FromDIP((760, 430)))
        dialog.CentreOnParent()
        rows.SetFocus()
        return dialog

    def choose_insight_account(self, title):
        if not self.all_accounts:
            return self.active_account if self.signed_in else None
        available = [account for account in self.accounts if self.is_signed_in(account["id"])]
        if len(available) <= 1:
            return available[0] if available else None
        choices = [f'{account["name"]} ({MARKETPLACES.get(account["marketplace"], account["marketplace"])})'
                   for account in available]
        with wx.SingleChoiceDialog(self, "Choose an Audible account.", title, choices) as dialog:
            if dialog.ShowModal() == wx.ID_OK:
                return available[dialog.GetSelection()]
        return None

    def title_offer_options(self, account):
        return dict(self.library_options(), preferWidevine=bool(account.get("widevine_enabled")))

    def show_title_check(self, book):
        from .insights import show_title_check

        account = self.book_account(book)
        if account and self.is_signed_in(account["id"]):
            show_title_check(self.frame, self.client, account, book, self.title_offer_options(account))

    def show_annotations(self, book):
        from .reading_views import AnnotationsDialog

        account = self.book_account(book)
        if account and self.is_signed_in(account["id"]):
            with AnnotationsDialog(self.frame, self.client, account["id"], book, self.library_options(),
                                   account_name=account["name"]) as dialog:
                dialog.ShowModal()

    def show_quality_audit(self):
        from .insights import show_quality_audit

        account = self.choose_insight_account("Check for Better-Quality Audio")
        if account:
            books = [book for book in self.books if profile_id(book, self.active_account_id) == account["id"]]
            available = [(book, paths) for book in books if (paths := self.frame.files_for_book(book))]
            options = dict(self.title_offer_options(account), quality="best")
            options["preferWidevine"] = options["format"] == "preferAAX" and options["preferWidevine"]
            if options["preferWidevine"]:
                try:
                    options["preferWidevine"] = bool(self.client.widevine_cdm(account["id"]))
                except AudibleError as error:
                    show_error(self, error)
                    return
            show_quality_audit(self.frame, self.client, account, available, options,
                               lambda chosen: self.frame.enqueue_books(chosen, DEFAULT_DOWNLOAD, upgrade=options))

    def show_listening_stats(self):
        from .insights import show_listening_stats

        available = [account for account in self.accounts if self.is_signed_in(account["id"])]
        current = next((account for account in available if account["id"] == self.active_account_id), None)
        if current or available:
            show_listening_stats(self.frame, self.client, current or available[0], accounts=available)

    def close_catalogue(self):
        self.catalogue_timer.Stop()
        if self._refresh_request is not None:
            self._refresh_request.set()

    def _menu_action(self, menu, title, action, enabled=True):
        item = menu.Append(wx.ID_ANY, title)
        item.Enable(enabled)
        menu.Bind(wx.EVT_MENU, lambda event: self.frame.guard(action), item)

    def populate_folder_actions(self, menu):
        folder = self.frame.matched_folder()
        self._menu_action(menu, "Match Existing Folder…", lambda: self.frame.match_files([], folder=True),
                          self.signed_in and not self.all_accounts)
        self._menu_action(menu, "Rescan Matched Folder", lambda: self.frame.scan_archive(deliberate=True),
                          self.signed_in and folder is not None)
        self._menu_action(menu, "Show Matched Folder in File Explorer", lambda: self.frame.open_file(folder),
                          self.signed_in and folder is not None and folder.is_dir())
        self._menu_action(menu, "Stop Matching This Folder", self.frame.stop_matching_folder,
                          self.signed_in and folder is not None)

    def populate_selected_book_actions(self, menu, books):
        book = books[0] if len(books) == 1 else None
        matches = self.frame.match_paths(book) if book else []
        owners = {profile_id(selected, self.active_account_id) for selected in books}
        active_only = owners == {self.active_account_id}
        self._menu_action(menu, "Edit Book…", lambda: self.frame.media_views.edit(book), book is not None and active_only)
        caption = "Change Matched Files…" if matches else "Match to Audio Files…"
        self._menu_action(menu, caption, lambda: self.frame.match_files(books), book is not None and active_only)
        self._menu_action(menu, "Remove File Match", lambda: self.frame.remove_matches(books), bool(matches) and active_only)
        if book is not None:
            signed_in = self.is_signed_in(profile_id(book, self.active_account_id))
            self._menu_action(menu, "Check This Title…", lambda: self.show_title_check(book), signed_in)
            self._menu_action(menu, "View Annotations…", lambda: self.show_annotations(book), signed_in)
        self._menu_action(menu, "Tags…", lambda: self.edit_tags(books), bool(books))
        self._menu_action(menu, "Export Selected to Goodreads…", lambda: self.export_to_goodreads(books), bool(books))
        files = sorted({path for selected in books for path in self.frame.files_for_book(selected) if path.is_file()})
        cue_files = [path for path in files if supports_cue(path)]
        if book is not None and len(cue_files) == 1:
            self._menu_action(menu, "Export CUE Sheet…", lambda: self.frame.media_views.export_cue(cue_files[0]),
                              not self.frame.media_views.cue_work.running)
        self._menu_action(menu, "Show Audio in File Explorer", lambda: self.open_paths(files, self.frame.show_file), bool(files))
        self._menu_action(menu, "Open Audio in Default Player", lambda: self.open_paths(files, self.frame.open_file), bool(files))
        menu.AppendSeparator()
        self._menu_action(menu, "Copy Title", lambda: self.copy_value(books, "title"), book is not None)
        self._menu_action(menu, "Copy ASINs" if len(books) > 1 else "Copy ASIN",
                          lambda: self.copy_value(books, "asin"), bool(books))

    def populate_account_actions(self, menu):
        self._menu_action(menu, "Add Account…" if self.signed_in else "Sign In…", self.connect_account)
        self._menu_action(menu, "Import Account…", self.import_account)
        self._menu_action(menu, "Sign Out", self.sign_out_active, self.signed_in and self.can_remove_accounts())

    def show_actions(self):
        menu = wx.Menu()
        try:
            signed_in = self.is_signed_in(self.active_account_id)
            self._menu_action(menu, "Find in Library", self.focus_search, self.browsing)
            self._menu_action(menu, "Recheck Saved Files", self.frame.recheck_saved_files, self.browsing)
            self._menu_action(menu, "Refresh All Accounts", lambda: self.refresh(all_accounts=True), bool(self.accounts))
            self._menu_action(menu, "Library Changes…", self.show_library_changes, bool(self.accounts))
            saved = wx.Menu()
            self.populate_saved_views(saved)
            menu.AppendSubMenu(saved, "Saved Views")
            menu.AppendSeparator()
            self.populate_folder_actions(menu)
            self._menu_action(menu, "Verify and Repair Archive…", self.frame.media_views.verify, signed_in and not self.all_accounts)
            menu.AppendSeparator()
            self._menu_action(menu, "Export Library…", self.export_books, bool(self.books))
            self._menu_action(menu, "Export Visible Results…", lambda: self.export_books(True), bool(self.list.rows))
            self._menu_action(menu, "Export Visible Results to Goodreads…", self.export_to_goodreads, bool(self.list.rows))
            self._menu_action(menu, "Library Status…", self.show_library_status)
            self._menu_action(menu, "Audible Tools…", self.audible_tools, signed_in)
            self._menu_action(menu, "Download Missing PDFs…", self.frame.request_missing_pdfs, bool(self.books))
            if books := self.selected_books():
                selected = wx.Menu()
                self.populate_selected_book_actions(selected, books)
                menu.AppendSubMenu(selected, "Selected Books")
            self.actions_button.PopupMenu(menu)
        finally:
            menu.Destroy()

    def context_menu(self, event):
        position = event.GetPosition()
        if position == wx.DefaultPosition:
            index = self.list.GetFocusedItem()
        else:
            index, _flags, _column = self.list.HitTestSubItem(self.list.ScreenToClient(position))
            if index == wx.NOT_FOUND:
                return
        if index != wx.NOT_FOUND and not self.list.IsSelected(index):
            for selected in list(selected_rows(self.list)):
                self.list.Select(selected, False)
            self.list.Select(index)
            self.list.Focus(index)
        books = self.selected_books()
        if not books:
            return
        menu = wx.Menu()
        try:
            downloadable = self.frame.downloadable_books(books)
            if self.frame.can_add_downloads():
                additions = self.frame.download_queue_additions(books)
                self._menu_action(menu, "Add Selected to Queue…", lambda: self.frame.review_add(additions), bool(additions))
            else:
                ready = bool(downloadable) and not self.frame.queue.pending
                self._menu_action(menu, "Download Selected", lambda: self.frame.request_selected_downloads(books), ready)
                self._menu_action(menu, "Download Selected As…", lambda: self.frame.review_download(books), ready)
                partial = any(book.get("isDownloadable") and self.frame.has_incomplete_download(book) for book in books)
                self._menu_action(menu, "Restart Incomplete Downloads…", self.restart_selected_downloads,
                                  partial and not self.frame.queue.pending)
            menu.AppendSeparator()
            self.populate_selected_book_actions(menu, books)
            self.list.PopupMenu(menu)
        finally:
            menu.Destroy()

    def open_paths(self, paths, action):
        for path in paths:
            self.frame.guard(action, path)

    def copy_value(self, books, key):
        if wx.TheClipboard.Open():
            try:
                wx.TheClipboard.SetData(wx.TextDataObject("\n".join(label(book.get(key)) for book in books)))
            finally:
                wx.TheClipboard.Close()

    def _show_window(self, key, factory):
        dialog = self._windows.get(key)
        if dialog:
            dialog.Raise()
        else:
            dialog = factory()
            self._windows[key] = dialog

            def close(_event):
                self._windows.pop(key, None)
                dialog.Destroy()

            dialog.Bind(wx.EVT_CLOSE, close)
            dialog.CentreOnParent()
            dialog.Show()
        return dialog

    def manage_accounts(self):
        return self._show_window("accounts", lambda: AccountsDialog(self.frame, self))

    def restart_selected_downloads(self):
        books = [book for book in self.selected_books() if book.get("isDownloadable")]
        self.frame.review_download(books, restart=True)

    def connect_account(self):
        return self.add_account() if self.signed_in else self.reconnect()

    def add_account(self):
        return self.open_account_dialog(SignInDialog)

    def reconnect(self):
        return self.open_account_dialog(SignInDialog, self.active_account)

    def sign_out_active(self):
        if self.signed_in and self.can_remove_accounts():
            self.sign_out(self.active_account_id)

    def import_account(self):
        return self.open_account_dialog(ImportAccountDialog)

    def open_account_dialog(self, dialog_class, *args):
        parent = wx.GetActiveWindow() or self.frame
        with dialog_class(parent, self, *args) as dialog:
            if dialog.ShowModal() == wx.ID_OK:
                if accounts := self._windows.get("accounts"):
                    accounts.refresh(dialog.account_id)

    def audible_tools(self):
        from .audible_tools import AudibleToolsDialog

        return self._show_window("tools", lambda: AudibleToolsDialog(self.frame, self))

    def wishlist(self):
        dialog = self.audible_tools()
        dialog.tabs.SetSelection(0)
        return dialog

    def show_library_status(self):
        return self._show_window("status", lambda: LibraryStatusDialog(self.frame, self))


class LibraryStatusDialog(wx.Dialog):
    def __init__(self, parent, library):
        super().__init__(parent, title="Library Status", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.library = library
        self.sort_field, self.sort_reverse = "title", False
        self.statuses = wx.ListBox(self, choices=list(STATUS_GROUPS), name="Library status categories", size=(170, -1))
        self.statuses.SetSelection(0)
        self.statuses.Bind(wx.EVT_LISTBOX, lambda event: self.render())
        self.list = BookList(self, name="Library status books", columns=(
            ("Title", "title", 177), ("Author", "authors", 107), ("Local Audio", "status", 113),
            ("Audible Download", "availability", 125), ("Transfer", "transfer", 80),
        ))
        self.list.Bind(wx.EVT_LIST_COL_CLICK, self.sort_column)
        self.summary = wx.StaticText(self, label=" ", name="Library status details")
        self.account = wx.StaticText(self, label=" ")
        detail = wx.BoxSizer(wx.VERTICAL)
        detail.Add(self.account, 0, wx.BOTTOM, 6)
        detail.Add(self.summary, 0, wx.EXPAND | wx.BOTTOM, 8)
        detail.Add(self.list, 1, wx.EXPAND)
        content = wx.BoxSizer(wx.HORIZONTAL)
        content.Add(self.statuses, 0, wx.EXPAND | wx.RIGHT, 10)
        content.Add(detail, 1, wx.EXPAND)
        box = wx.BoxSizer(wx.VERTICAL)
        box.Add(content, 1, wx.EXPAND | wx.ALL, 10)
        close = button(self, "Close", self.Close)
        self.SetEscapeId(close.GetId())
        box.Add(close, 0, wx.ALIGN_RIGHT | wx.RIGHT | wx.BOTTOM, 10)
        self.SetSizer(box)
        self.SetMinSize((640, 340))
        self.SetSize((860, 455))
        self.render()

    def sort_column(self, event):
        _, field, _ = self.list.columns[event.GetColumn()]
        self.sort_reverse = not self.sort_reverse if field == self.sort_field else False
        self.sort_field = field
        self.render()

    def render(self):
        selected = max(self.statuses.GetSelection(), 0)
        names = list(STATUS_GROUPS)
        filter_by = names[selected]
        transfers = self.library.frame.library_transfers()
        groups = {name: [] for name in names}
        for book in self.library.books:
            status = self.library.status_for(book)
            downloadable = book.get("isDownloadable")
            availability = "Available" if downloadable else AVAILABILITY.get(book.get("downloadUnavailableReason"), "Unavailable")
            row = dict(book, local_audio="No local audio" if status == "Unavailable" else status,
                       availability=availability, transfer=transfers.get(book_identity(book, self.library.active_account_id), ""))
            groups["All Audiobooks"].append(row)
            category = status if status in {"Downloaded", "Matched"} else "To Download" if downloadable else "Unavailable"
            groups[category].append(row)
        labels = [f"{name} ({len(groups[name])})" for name in names]
        if self.statuses.GetStrings() != labels:
            self.statuses.Set(labels)
            self.statuses.SetSelection(selected)
        matching = browse_books(groups[filter_by], "", {}, self.sort_field, self.sort_reverse, lambda book: book["local_audio"])
        self.list.set_books(matching, lambda book: self.library.display_status(book, book["local_audio"]))
        for column, (title, field, _) in enumerate(self.list.columns):
            item = self.list.GetColumn(column)
            arrow = " ↓" if self.sort_reverse else " ↑"
            heading = title + arrow if field == self.sort_field else title
            if item.GetText() != heading:
                item.SetText(heading)
                self.list.SetColumn(column, item)
        account = "All Accounts" if self.library.all_accounts else next(
            (item["name"] for item in self.library.accounts if item["id"] == self.library.active_account_id), "")
        self.account.SetLabel(account)
        if not self.library.browsing:
            self.summary.SetLabel("Sign in to see your audiobook status.")
        elif matching:
            self.summary.SetLabel(STATUS_GROUPS[filter_by])
        else:
            self.summary.SetLabel("No audiobooks in this category.")
        self.summary.Wrap(max(self.GetClientSize().GetWidth() - 200, 300))
        self.Layout()

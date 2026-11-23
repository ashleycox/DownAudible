"""Read-only Audible reports and exports for the native desktop app."""

import calendar
import csv
import io
import json
import threading
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import wx

from .audible import MARKETPLACES, AudibleError, write_atomic
from .audible_dialogs import accessible_name, add_field, button, run_async, show_error
from .media import MediaCancelled, MediaError, MediaTools
from .spreadsheet import workbook_data


FORMATS = ((".json", "JSON"), (".csv", "CSV"), (".tsv", "TSV"), (".xlsx", "Excel"))
OFFER_STATES = {
    "available": "Available",
    "notOffered": "Unavailable",
    "notChecked": "Not checked",
    "denied": "Refused by Audible",
    "error": "Could not check",
}
AUDIT_INTERRUPTS = {"authorization", "licenseThrottled", "rateLimited", "serverUnavailable"}
QUALITY_FLOWS = {"aaxOnly": ("aax",), "aaxcOnly": ("aaxc",)}
FORMAT_NAMES = {"aax": "AAX", "aaxc": "AAXC", "widevine": "Widevine stereo"}
REASONS = {
    "widevineDisabled": "Widevine is off for this account.",
    "widevineUnavailable": "Audible did not offer Widevine stereo for this title.",
}


def time_label(milliseconds):
    hours, remainder = divmod(milliseconds // 1000, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours} h {minutes} min {seconds} s"


def export_month(milliseconds):
    hours, remainder = divmod(milliseconds // 1000, 3600)
    minutes, seconds = divmod(remainder, 60)
    return dict(hours=hours, minutes=minutes, seconds=seconds, durationMilliseconds=milliseconds)


def month_rows(months, year=None, month=None, hide_empty=False):
    return [row for row in months if (year is None or row["month"][:4] == year)
            and (month is None or int(row["month"][-2:]) == month)
            and (not hide_empty or row["durationMilliseconds"] > 0)]


def listening_export(months, suffix):
    if suffix == ".json":
        intervals = {row["month"]: export_month(row["durationMilliseconds"]) for row in months}
        return (json.dumps(intervals, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    headers = ("Month", "Listening Time", "Duration (Milliseconds)")
    rows = [(row["month"], time_label(row["durationMilliseconds"]), row["durationMilliseconds"]) for row in months]
    if suffix == ".xlsx":
        return workbook_data(headers, rows, title="Listening Statistics")
    if suffix not in {".csv", ".tsv"}:
        raise ValueError("Choose JSON, CSV, TSV, or Excel.")
    output = io.StringIO(newline="")
    writer = csv.writer(output, delimiter="," if suffix == ".csv" else "\t")
    writer.writerow(headers)
    writer.writerows(rows)
    return output.getvalue().encode("utf-8")


def offer_details(offer):
    values = []
    if codec := offer.get("codec"):
        values.append(codec)
    if rate := offer.get("bitrateKbps"):
        values.append(f"{'about ' if offer.get('bitrateEstimated') else ''}{rate} kbps")
    if channels := offer.get("channels"):
        values.append(f"{channels} channels")
    return " · ".join(values)


def offer_reason(offer):
    reason = offer.get("reason")
    if reason in REASONS:
        return REASONS[reason]
    return str(AudibleError(reason)) if reason else ""


def preferred_offer(offers, options):
    formats = QUALITY_FLOWS.get(options.get("format"))
    if formats is None:
        formats = ("widevine", "aax", "aaxc") if options.get("preferWidevine") else ("aax", "aaxc")
    by_format = {offer["format"]: offer for offer in offers}
    for name in formats:
        offer = by_format.get(name, {})
        if offer.get("status") == "available":
            return offer
        if offer.get("status") in {"error", "denied"}:
            return None
    return None


def _table(owner, columns, name, *, select_many=False):
    style = wx.LC_REPORT | (0 if select_many else wx.LC_SINGLE_SEL)
    ctrl = wx.ListCtrl(owner, style=style, name=name)
    accessible_name(ctrl, name)
    for index, (label, width) in enumerate(columns):
        ctrl.InsertColumn(index, label, width=width)
    return ctrl


def _set_rows(table, rows):
    table.Freeze()
    try:
        table.DeleteAllItems()
        for values in rows:
            row = table.InsertItem(table.GetItemCount(), str(values[0]))
            for column, value in enumerate(values[1:], start=1):
                table.SetItem(row, column, str(value))
    finally:
        table.Thaw()


class _ReportDialog(wx.Dialog):
    def __init__(self, parent, title, width, height):
        super().__init__(parent, title=title, style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.closed = threading.Event()
        self.box = wx.BoxSizer(wx.VERTICAL)
        self.SetSizer(self.box)
        self.SetMinSize((width - 45, height - 40))
        self.SetSize((width, height))
        self.Bind(wx.EVT_WINDOW_DESTROY, self._destroyed)

    def _destroyed(self, event):
        if event.GetEventObject() is self:
            self.closed.set()
            self.cancel_work()
        event.Skip()

    def cancel_work(self):
        pass

    def add(self, element, proportion=0, flags=wx.EXPAND):
        self.box.Add(element, proportion, flags | wx.LEFT | wx.RIGHT | wx.TOP, 12)

    def footer(self, *actions):
        row = wx.BoxSizer(wx.HORIZONTAL)
        for action in actions:
            row.Add(action, 0, wx.RIGHT, 8)
        row.AddStretchSpacer()
        close = wx.Button(self, wx.ID_CANCEL, label="Close")
        row.Add(close)
        self.box.Add(row, 0, wx.EXPAND | wx.ALL, 12)
        self.SetEscapeId(wx.ID_CANCEL)


class TitleCheckDialog(_ReportDialog):
    def __init__(self, parent, client, account, book, options):
        super().__init__(parent, "Check This Title", 825, 395)
        self.client, self.account, self.book, self.options = client, account, book, options
        self.report = None
        self.add(wx.StaticText(self, label=book.get("title") or book["asin"]))
        self.add(wx.StaticText(self, label=f"ASIN {book['asin']} · Marketplace {account.get('marketplace', '').upper()}"))
        self.table = _table(self, (("Format", 122), ("Status", 125), ("Audio", 204), ("Details", 328)), "Audible audio offers")
        self.add(self.table, 1)
        self.status = wx.StaticText(self, label="Checking Audible…")
        self.add(self.status)
        self.copy = button(self, "Copy Redacted Report", self.copy_report)
        self.copy.Disable()
        self.retry = button(self, "Retry", self.read)
        self.footer(self.copy, self.retry)
        self.read()

    def read(self):
        self.retry.Disable()
        self.copy.Disable()
        self.status.SetLabel("Checking Audible…")
        run_async(self, lambda: self.client.run("checkTitle", account_id=self.account["id"], asin=self.book["asin"],
                                                options=self.options, cancel=self.closed),
                  self.loaded, failure=self.failed, cancel=self.closed)

    def loaded(self, result):
        self.report = result.get("offers", ())
        _set_rows(self.table, [
            (FORMAT_NAMES.get(offer["format"], offer["format"]), OFFER_STATES.get(offer.get("status"), "Unknown"),
             offer_details(offer), offer_reason(offer)) for offer in self.report
        ])
        self.status.SetLabel("Title check complete.")
        self.retry.Enable()
        self.copy.Enable()

    def failed(self, error):
        self.status.SetLabel(str(error))
        self.retry.Enable()

    def copy_report(self):
        title = f"DownAudible title check\nASIN {self.book['asin']}\nMarketplace {self.account.get('marketplace', '').upper()}"
        lines = [" · ".join(value for value in (
            FORMAT_NAMES.get(offer["format"], offer["format"]), OFFER_STATES.get(offer.get("status"), "Unknown"),
            offer_details(offer), offer_reason(offer)
        ) if value) for offer in self.report]
        if wx.TheClipboard.Open():
            try:
                if wx.TheClipboard.SetData(wx.TextDataObject("\n".join([title, *lines]))):
                    self.status.SetLabel("Redacted report copied.")
            finally:
                wx.TheClipboard.Close()


class ListeningStatisticsDialog(_ReportDialog):
    def __init__(self, parent, client, account, accounts=None):
        super().__init__(parent, "Listening Statistics", 730, 495)
        self.client = client
        self.accounts = list(accounts or [account])
        self.months = []
        self.years = []
        self.has_loaded = False
        self.loading = None
        year_form = wx.BoxSizer(wx.VERTICAL)
        labels = []
        for item in self.accounts:
            marketplace = MARKETPLACES.get(item["marketplace"], item["marketplace"])
            labels.append(f'{item["name"]} ({marketplace})')
        self.account = wx.Choice(self, choices=labels, name="Audible account")
        self.account.SetSelection(next((index for index, item in enumerate(self.accounts) if item["id"] == account["id"]), 0))
        accessible_name(self.account, "Audible account")
        add_field(year_form, self, "Audible account", self.account)
        self.account.Bind(wx.EVT_CHOICE, self.account_changed)
        self.start_year = wx.SpinCtrl(self, min=1997, max=date.today().year, initial=2010, size=(96, -1), name="Start year")
        add_field(year_form, self, "Start year", self.start_year)
        self.add(year_form)
        self.load_button = button(self, "Load Statistics", self.load)
        self.cancel_button = button(self, "Cancel Loading", self.cancel_work)
        self.cancel_button.Disable()
        action_row = wx.BoxSizer(wx.HORIZONTAL)
        action_row.Add(self.load_button, 0, wx.RIGHT, 8)
        action_row.Add(self.cancel_button)
        self.add(action_row)
        filter_row = wx.BoxSizer(wx.HORIZONTAL)
        self.year = wx.Choice(self, choices=["All years"], name="Year")
        self.month = wx.Choice(self, choices=["All months", *calendar.month_name[1:]], name="Month")
        for control, name in ((self.year, "Year"), (self.month, "Month")):
            caption = wx.StaticText(self, label=name)
            filter_row.Add(caption, 0, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, 8)
            filter_row.Add(control, 0, wx.RIGHT, 12)
            control.SetSelection(0)
            accessible_name(control, name)
            control.Bind(wx.EVT_CHOICE, lambda _event: self.render())
            control.Disable()
        self.hide_empty = wx.CheckBox(self, label="Hide months with no listening")
        self.hide_empty.Bind(wx.EVT_CHECKBOX, lambda _event: self.render())
        self.hide_empty.Disable()
        filter_row.Add(self.hide_empty, 0, wx.ALIGN_CENTER_VERTICAL)
        self.add(filter_row)
        self.table = _table(self, (("Month", 155), ("Listening Time", 310)), "Monthly listening statistics")
        self.add(self.table, 1)
        self.status = wx.StaticText(self, label="Choose a start year to see monthly listening time.")
        self.add(self.status)
        self.export_button = button(self, "Export…", self.export)
        self.export_button.Disable()
        self.footer(self.export_button)

    def cancel_work(self):
        if self.loading is not None:
            self.loading.set()

    def account_changed(self, _event):
        self.months = []
        self.has_loaded = False
        self.year.SetItems(["All years"])
        self.year.SetSelection(0)
        self.month.SetSelection(0)
        self.hide_empty.SetValue(False)
        for control in (self.year, self.month, self.hide_empty):
            control.Disable()
        self.status.SetLabel("Choose a start year to see monthly listening time.")
        self.render()

    def load(self):
        if self.loading is not None:
            return
        self.loading = threading.Event()
        cancel = self.loading
        year = self.start_year.GetValue()
        account_id = self.accounts[self.account.GetSelection()]["id"]
        self.account.Disable()
        self.load_button.Disable()
        self.start_year.Disable()
        self.cancel_button.Enable()
        self.status.SetLabel("Loading listening statistics…")

        def work():
            try:
                return self.client.run("listeningStats", account_id=account_id, startYear=year, cancel=cancel)
            except AudibleError as error:
                if error.code == "cancelled":
                    return None
                raise

        run_async(self, work, self.loaded, failure=lambda error: self.status.SetLabel(str(error)),
                  done=self.unbusy, cancel=self.closed)

    def unbusy(self):
        self.loading = None
        self.account.Enable()
        self.load_button.Enable()
        self.start_year.Enable()
        self.cancel_button.Disable()

    def loaded(self, value):
        if value is None:
            self.status.SetLabel("Loading cancelled.")
            return
        previous = self.year.GetStringSelection()
        self.months = sorted(value["months"], key=lambda row: row["month"])
        self.years = sorted({row["month"][:4] for row in self.months}, reverse=True)
        self.year.SetItems(["All years", *self.years])
        self.year.SetSelection(self.years.index(previous) + 1 if previous in self.years else 0)
        for control in (self.year, self.month, self.hide_empty):
            control.Enable()
        self.has_loaded = True
        self.render()

    def visible(self):
        year = self.year.GetStringSelection() if self.year.GetSelection() > 0 else None
        month = self.month.GetSelection() if self.month.GetSelection() > 0 else None
        return month_rows(self.months, year, month, self.hide_empty.GetValue())

    def render(self):
        rows = self.visible()
        _set_rows(self.table, [(row["month"], time_label(row["durationMilliseconds"])) for row in rows])
        if self.has_loaded:
            total = time_label(sum(row["durationMilliseconds"] for row in rows))
            months = "month" if len(rows) == 1 else "months"
            self.status.SetLabel(f"{len(rows)} {months} · {total}" if rows else "No matching months.")
        self.export_button.Enable(bool(rows))

    def export(self):
        rows = self.visible()
        wildcard = "|".join(f"{name} (*{suffix})|*{suffix}" for suffix, name in FORMATS)
        with wx.FileDialog(self, "Export Listening Statistics", defaultFile="listening-stats",
                           wildcard=wildcard, style=wx.FD_SAVE | wx.FD_OVERWRITE_PROMPT) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return
            path = Path(dialog.GetPath())
            suffix = path.suffix.lower()
            if suffix not in dict(FORMATS):
                suffix = FORMATS[dialog.GetFilterIndex()][0]
                path = path.with_suffix(suffix)
            try:
                write_atomic(path, listening_export(rows, suffix))
            except OSError:
                show_error(self, AudibleError("fileAccess"))
            except ValueError as error:
                wx.MessageBox(str(error), "Could Not Export", wx.OK | wx.ICON_ERROR, self)


@dataclass(frozen=True)
class QualityRow:
    book: dict
    saved: str
    offer: str
    upgrade: bool = False


def saved_quality(media, files, cancel):
    best = None
    for file in files:
        try:
            audio = media.probe(Path(file), metadata_only=True, cancel=cancel).audio
        except MediaCancelled:
            raise
        except MediaError:
            continue
        rate = audio.get("bit_rate")
        bitrate = (int(rate) + 500) // 1000 if str(rate).isdigit() and int(rate) >= 1000 else None
        current = dict(codec=" ".join(filter(None, ((audio.get("codec_name") or "").upper(), audio.get("profile")))),
                       bitrateKbps=bitrate, channels=audio.get("channels"))
        if best is None or (bitrate or 0) > (best.get("bitrateKbps") or 0):
            best = current
    return best or {}


def audit_quality(client, account_id, inputs, options, media, cancel, report_progress):
    rows = []
    for book, files in inputs:
        if cancel.is_set():
            break
        try:
            saved = saved_quality(media, files, cancel)
            response = client.run("checkTitle", account_id=account_id, asin=book["asin"], options=options,
                                  preferredAudioOnly=True, cancel=cancel)
            offers = response.get("offers", ())
            offer = preferred_offer(offers, options)
        except MediaCancelled:
            break
        except AudibleError as error:
            if error.code == "cancelled":
                break
            rows.append(QualityRow(book, "Unknown", str(error)))
            report_progress(len(rows))
            if error.code in AUDIT_INTERRUPTS:
                return rows, str(error)
            continue
        bitrate = saved.get("bitrateKbps")
        proposed = (offer or {}).get("bitrateKbps")
        same_channels = (not offer or not offer.get("channels") or not saved.get("channels")
                         or offer["channels"] == saved["channels"])
        upgrade = (same_channels and bool(bitrate and proposed)
                   and proposed - bitrate > (2 if offer.get("bitrateEstimated") else 0))
        if offer:
            label = " · ".join(filter(None, (FORMAT_NAMES.get(offer["format"], offer["format"]), offer_details(offer))))
        else:
            failures = [entry for entry in offers if entry.get("status") in {"denied", "error"}]
            label = next((reason for entry in (*failures, *offers) if (reason := offer_reason(entry))), "No comparable offer")
        rows.append(QualityRow(book, offer_details(saved) or "Unknown", label, upgrade))
        report_progress(len(rows))
        interruption = next((entry["reason"] for entry in offers if entry.get("reason") in AUDIT_INTERRUPTS), None)
        if interruption:
            return rows, str(AudibleError(interruption))
    return rows, "Check stopped." if cancel.is_set() else ""


class QualityAuditDialog(_ReportDialog):
    def __init__(self, parent, client, account, inputs, options, queue_upgrades):
        super().__init__(parent, "Check for Better-Quality Audio", 915, 492)
        self.client, self.account, self.inputs = client, account, list(inputs)
        self.options = dict(options or {}, quality="best")
        self.options.setdefault("preferWidevine", account.get("widevine_enabled") is True)
        self.queue_upgrades = queue_upgrades
        self.checking = None
        media_dir = client.resource_dir / "Media"
        self.media = MediaTools(media_dir / "ffmpeg.exe", media_dir / "ffprobe.exe")
        self.rows = []
        self.visible = []
        self.add(wx.StaticText(self, label=f"Audible account {account.get('name') or account.get('marketplace', '')} · Best quality"))
        self.only_upgrades = wx.CheckBox(self, label="Show higher-bitrate offers only")
        self.only_upgrades.Bind(wx.EVT_CHECKBOX, lambda _event: self.render())
        self.add(self.only_upgrades)
        self.table = _table(self, (("Title", 235), ("Saved Audio", 187), ("Audible Offer", 315), ("Result", 116)),
                            "Saved audio and Audible offers", select_many=True)
        for event_type in (wx.EVT_LIST_ITEM_SELECTED, wx.EVT_LIST_ITEM_DESELECTED):
            self.table.Bind(event_type, lambda _event: self.update_queue())
        self.add(self.table, 1)
        self.status = wx.StaticText(self, label=f"Check {len(self.inputs)} saved titles. Queue the higher-bitrate copies you want to keep.")
        self.add(self.status)
        self.check_button = button(self, "Check Audio", self.check)
        self.check_button.Enable(bool(self.inputs))
        self.stop = button(self, "Stop Check", self.cancel_work)
        self.stop.Disable()
        self.queue = button(self, "Queue Selected as New Copies", self.queue_selected)
        self.queue.Disable()
        self.footer(self.check_button, self.stop, self.queue)

    def cancel_work(self):
        if self.checking is not None:
            self.checking.set()

    def check(self):
        if self.checking is not None:
            return
        self.checking = threading.Event()
        stop = self.checking
        self.rows = []
        self.render()
        self.check_button.Disable()
        self.stop.Enable()
        self.progress(0)
        run_async(self, lambda: audit_quality(self.client, self.account["id"], self.inputs, self.options, self.media,
                                              stop, lambda count: wx.CallAfter(self.progress, count)),
                  self.checked, failure=lambda error: self.status.SetLabel(str(error)), done=self.unbusy, cancel=self.closed)

    def progress(self, count):
        if self and not self.closed.is_set() and self.checking is not None:
            self.status.SetLabel(f"Checked {count} of {len(self.inputs)} books.")

    def unbusy(self):
        self.checking = None
        self.stop.Disable()
        self.check_button.SetLabel("Check Again")
        self.check_button.Enable(bool(self.inputs))

    def checked(self, result):
        self.rows, issue = result
        self.render()
        upgrades = sum(row.upgrade for row in self.rows)
        offers = "offer" if upgrades == 1 else "offers"
        self.status.SetLabel(issue or f"{len(self.rows)} checked · {upgrades} higher-bitrate {offers}.")

    def render(self):
        self.visible = [row for row in self.rows if row.upgrade or not self.only_upgrades.GetValue()]
        _set_rows(self.table, [(row.book.get("title") or row.book["asin"], row.saved, row.offer,
                               "Higher bitrate" if row.upgrade else "Review") for row in self.visible])
        self.update_queue()

    def selected(self):
        selected = []
        index = self.table.GetFirstSelected()
        while 0 <= index < len(self.visible):
            if self.visible[index].upgrade:
                selected.append(self.visible[index].book)
            index = self.table.GetNextSelected(index)
        return selected

    def update_queue(self):
        self.queue.Enable(self.checking is None and bool(self.selected()))

    def queue_selected(self):
        if self.queue_upgrades(self.selected()) is not False:
            self.EndModal(wx.ID_OK)


def show_title_check(parent, client, account, book, options=None):
    with TitleCheckDialog(parent, client, account, book, options or {}) as dialog:
        dialog.ShowModal()


def show_quality_audit(parent, client, account, books_with_audio, options, queue_upgrades):
    with QualityAuditDialog(parent, client, account, books_with_audio, options, queue_upgrades) as dialog:
        dialog.ShowModal()


def show_listening_stats(parent, client, account, *, accounts=None):
    with ListeningStatisticsDialog(parent, client, account, accounts) as dialog:
        dialog.ShowModal()

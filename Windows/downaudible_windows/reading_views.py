"""Native annotation browser and Goodreads export preview."""

import threading
from pathlib import Path

import wx

from .audible import AudibleError, write_atomic
from .audible_dialogs import accessible_name, button, run_async, show_error
from .reading_data import (
    annotation_data,
    annotation_rows,
    filter_annotations,
    goodreads_data,
    goodreads_rows,
)
from .report_list import report_list


def _save_export(parent, title, filename, formats, data):
    extensions = [extension for extension, _ in formats]
    wildcard = "|".join(f"{name} (*{extension})|*{extension}" for extension, name in formats)
    with wx.FileDialog(parent, title, defaultFile=filename, wildcard=wildcard,
                       style=wx.FD_SAVE | wx.FD_OVERWRITE_PROMPT) as dialog:
        if dialog.ShowModal() != wx.ID_OK:
            return False
        path = Path(dialog.GetPath())
        if path.suffix.lower() not in extensions:
            path = path.with_suffix(extensions[dialog.GetFilterIndex()])
        try:
            write_atomic(path, data(path.suffix.lower()))
        except OSError:
            show_error(parent, AudibleError("fileAccess"))
            return False
    return True


def _actions(dialog, *controls):
    row = wx.BoxSizer(wx.HORIZONTAL)
    for control in controls:
        row.Add(control, 0, wx.RIGHT, dialog.FromDIP(8))
    row.AddStretchSpacer()
    row.Add(wx.Button(dialog, wx.ID_CANCEL, label="Close"))
    dialog.SetEscapeId(wx.ID_CANCEL)
    return row


def _fill_rows(table, rows):
    table.Freeze()
    try:
        table.DeleteAllItems()
        for values in rows:
            index = table.InsertItem(table.GetItemCount(), values[0])
            for column, value in enumerate(values[1:], 1):
                table.SetItem(index, column, value)
    finally:
        table.Thaw()


class AnnotationsDialog(wx.Dialog):
    def __init__(self, parent, client, account_id, book, options, *, account_name=""):
        super().__init__(parent, title="Annotations", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.client, self.account_id, self.book, self.options = client, account_id, book, options
        self.title = book.get("title") or book["asin"]
        self.annotations = []
        self.visible = []
        self.cancel = threading.Event()
        self.loading = False
        self.issue = None

        self.search = wx.SearchCtrl(self, name="Search Annotations")
        self.search.SetDescriptiveText("Search Annotations")
        accessible_name(self.search, "Search Annotations")
        self.search.Bind(wx.EVT_TEXT, lambda _event: self.render())
        self.search.Bind(wx.EVT_SEARCHCTRL_CANCEL_BTN, lambda _event: self.search.SetValue(""))
        self.search.ShowCancelButton(True)
        self.table = report_list(self, "Bookmarks and notes", (("Position", 92), ("Type", 112), ("Text", 245)),
                                 fill=2, style=wx.LC_SINGLE_SEL)
        self.table.Bind(wx.EVT_LIST_ITEM_SELECTED, lambda _event: self.show_detail())
        self.table.Bind(wx.EVT_LIST_ITEM_DESELECTED, lambda _event: self.show_detail())
        self.details = wx.TextCtrl(self, style=wx.TE_MULTILINE | wx.TE_READONLY, name="Annotation text")
        accessible_name(self.details, "Annotation text")
        self.details.SetMinSize((-1, self.FromDIP(74)))
        self.status = wx.StaticText(self)
        self.reload = button(self, "Reload", self.load)
        self.save = button(self, "Export…", self.export)

        box = wx.BoxSizer(wx.VERTICAL)
        caption = f"{self.title} · {account_name}" if account_name else self.title
        for control, proportion in ((wx.StaticText(self, label=caption), 0), (self.search, 0), (self.table, 1),
                                    (wx.StaticText(self, label="Annotation text"), 0), (self.details, 0),
                                    (self.status, 0), (_actions(self, self.reload, self.save), 0)):
            box.Add(control, proportion, wx.EXPAND | wx.BOTTOM, self.FromDIP(8))
        outer = wx.BoxSizer(wx.VERTICAL)
        outer.Add(box, 1, wx.EXPAND | wx.ALL, self.FromDIP(12))
        self.SetSizer(outer)
        self.SetMinSize(self.FromDIP((550, 415)))
        self.SetSize(self.FromDIP((690, 475)))
        self.CentreOnParent()
        self.SetAcceleratorTable(wx.AcceleratorTable([(wx.ACCEL_CTRL, ord("F"), wx.ID_FIND)]))
        self.Bind(wx.EVT_MENU, lambda _event: self.search.SetFocus(), id=wx.ID_FIND)
        self.Bind(wx.EVT_WINDOW_DESTROY, self.on_destroy)
        self.search.SetFocus()
        self.load()

    def on_destroy(self, event):
        if event.GetEventObject() is self:
            self.cancel.set()
        event.Skip()

    def load(self):
        if self.loading:
            return
        self.loading = True
        self.issue = None
        self.render_status()

        def fetch():
            return self.client.run("annotations", account_id=self.account_id, asin=self.book["asin"],
                                   options=self.options, cancel=self.cancel)

        run_async(self, fetch, self.loaded, failure=self.failed, cancel=self.cancel)

    def loaded(self, result):
        if not isinstance(result, dict) or not isinstance(result.get("entries"), list):
            self.failed(AudibleError("annotationsResponse"))
            return
        self.loading = False
        self.annotations = annotation_rows(result["entries"])
        self.render()

    def failed(self, error):
        self.loading = False
        self.issue = str(error)
        self.render_status()

    def render(self):
        self.visible = filter_annotations(self.annotations, self.search.GetValue())
        _fill_rows(self.table, ((row.position_label or "Unknown", row.type_label, " ".join(row.text.split()))
                                for row in self.visible))
        self.show_detail()
        self.render_status()

    def render_status(self):
        if self.loading:
            caption = "Loading annotations…"
        elif self.issue:
            caption = self.issue
        elif not self.annotations:
            caption = "No bookmarks or notes are available for this title."
        elif not self.visible:
            caption = "No annotations match your search."
        else:
            count = len(self.visible)
            caption = "1 annotation" if count == 1 else f"{count} annotations"
        self.status.SetLabel(caption)
        self.reload.Enable(not self.loading)
        self.save.Enable(bool(self.visible) and not self.loading)
        self.Layout()

    def show_detail(self):
        index = self.table.GetFirstSelected()
        selected = 0 <= index < len(self.visible)
        if selected:
            row = self.visible[index]
            note = row.text or f'{row.type_label} · {row.position_label or "Unknown"}'
        else:
            note = "Select a bookmark or note to read it here." if self.visible else ""
        self.details.ChangeValue(note)
        self.details.Enable(selected)

    def export(self):
        _save_export(self, "Export Annotations", "annotations", ((".md", "Markdown"), (".csv", "CSV")),
                     lambda extension: annotation_data(self.title, self.visible, extension))


class GoodreadsDialog(wx.Dialog):
    def __init__(self, parent, books):
        super().__init__(parent, title="Export to Goodreads", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.rows = goodreads_rows(books)
        count = sum(row.values is not None for row in self.rows)
        summary = f"{count} ready to export · {len(self.rows) - count} skipped"
        table = report_list(self, "Goodreads export preview",
                            (("Title", 175), ("Identifier", 155), ("Listening", 110), ("Status", 160)),
                            fill=0, style=wx.LC_SINGLE_SEL)
        self.table = table
        _fill_rows(table, ((row.title, row.identifier or "—", row.listening, row.status) for row in self.rows))
        self.save = button(self, "Export CSV…", self.export)
        self.save.SetDefault()
        self.save.Enable(count > 0)
        box = wx.BoxSizer(wx.VERTICAL)
        box.Add(wx.StaticText(self, label=summary), 0, wx.BOTTOM, self.FromDIP(8))
        box.Add(table, 1, wx.EXPAND | wx.BOTTOM, self.FromDIP(8))
        box.Add(_actions(self, self.save), 0, wx.EXPAND)
        outer = wx.BoxSizer(wx.VERTICAL)
        outer.Add(box, 1, wx.EXPAND | wx.ALL, self.FromDIP(12))
        self.SetSizer(outer)
        self.SetMinSize(self.FromDIP((650, 350)))
        self.SetSize(self.FromDIP((775, 390)))
        self.CentreOnParent()
        table.SetFocus()

    def export(self):
        if _save_export(self, "Export to Goodreads", "Goodreads Library.csv", ((".csv", "CSV"),),
                        lambda _extension: goodreads_data(self.rows)):
            self.EndModal(wx.ID_OK)

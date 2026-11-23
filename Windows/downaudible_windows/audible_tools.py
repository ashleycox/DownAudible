"""Audible wish list, catalogue, and account tools."""

from __future__ import annotations

import threading
from pathlib import Path

import wx

from .audible import AudibleError, write_atomic
from .audible_dialogs import (
    accessible_name,
    add_field,
    button,
    finish_dialog,
    run_async,
    shortcuts,
    text_field,
)
from .library import COLUMNS, BookList, browse_books, export_dialog, normalized

CATALOG_COLUMNS = (COLUMNS[0], COLUMNS[1], ("Series", "series", 130), ("ASIN", "asin", 102))


def filter_wishlist(books, query):
    query = normalized(query.strip())
    if not query:
        return books
    return [book for book in books if any(query in normalized(value) for value in (
        book.get("title") or "", book.get("asin") or "", book.get("series") or "", *(book.get("authors") or ()),
    ))]


class AudibleToolsDialog(wx.Dialog):
    def __init__(self, parent, library):
        super().__init__(parent, title="Audible Tools", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.library = library
        self.client = library.client
        self.account_id = library.active_account_id
        self.signed_in = library.is_signed_in(self.account_id)
        self.cancel = threading.Event()
        self.books = []
        self.activation = None
        self.activation_busy = False
        self.wishlist_busy = False
        self.wishlist_issue = ""
        self.tabs = wx.Notebook(self, name="Audible tools")
        self.wishlist_page = self.build_wishlist()
        self.account_page = self.build_account()
        self.tabs.AddPage(self.wishlist_page, "Wish List")
        self.tabs.AddPage(self.account_page, "Account")
        self.tabs.Bind(wx.EVT_NOTEBOOK_PAGE_CHANGED, self.tab_changed)
        box = wx.BoxSizer(wx.VERTICAL)
        box.Add(self.tabs, 1, wx.EXPAND | wx.ALL, 10)
        footer = wx.BoxSizer(wx.HORIZONTAL)
        self.account_name = wx.StaticText(self, label=" ", name="Active Audible account")
        footer.Add(self.account_name, 1, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, 10)
        close = button(self, "Close", self.Close)
        self.SetEscapeId(close.GetId())
        footer.Add(close)
        box.Add(footer, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 10)
        self.SetSizer(box)
        self.SetMinSize((560, 355))
        self.SetSize((760, 480))
        self.Bind(wx.EVT_WINDOW_DESTROY, self.destroyed)
        shifted = wx.ACCEL_CTRL | wx.ACCEL_SHIFT
        self._shortcuts = shortcuts(self, [
            (wx.ACCEL_CTRL, ord("F"), self.focus_wishlist_filter),
            (shifted, ord("A"), lambda: self.run_on_tab(0, self.add_button, self.open_catalog)),
            (shifted, wx.WXK_DELETE, lambda: self.run_on_tab(0, self.remove_button, self.remove)),
            (shifted, ord("R"), lambda: self.run_on_tab(0, self.refresh_button, self.refresh)),
            (shifted, ord("J"), lambda: self.run_on_tab(0, self.export_button, lambda: self.export(".json"))),
            (shifted, ord("G"), lambda: self.run_on_tab(0, self.export_button, lambda: self.export(".csv"))),
            (shifted, ord("T"), lambda: self.run_on_tab(0, self.export_button, lambda: self.export(".tsv"))),
            (shifted, ord("H"), lambda: self.run_on_tab(1, self.reveal_button, self.toggle_activation)),
            (shifted, ord("C"), lambda: self.run_on_tab(1, self.copy_button, self.copy_activation)),
            (shifted, ord("L"), lambda: self.run_on_tab(1, self.reload_button, lambda: self.fetch_activation(refresh=True))),
            (shifted, ord("E"), lambda: self.run_on_tab(1, self.export_account_button, self.export_account)),
        ])
        self.refresh_account_name()
        self.refresh()

    def refresh_account_name(self):
        name = next((item["name"] for item in self.library.accounts if item["id"] == self.account_id), "")
        self.account_name.SetLabel(name)

    def tab_changed(self, event):
        if event.GetSelection() == 0 and self.activation is not None:
            self.hide_activation()
        event.Skip()

    def focus_wishlist_filter(self):
        if self.tabs.GetSelection() == 0:
            self.filter.SetFocus()
            self.filter.SelectAll()

    def run_on_tab(self, index, control, action):
        if self.tabs.GetSelection() == index and control.IsEnabled():
            action()

    def destroyed(self, event):
        if event.GetEventObject() == self:
            self.cancel.set()
            self.activation = None
        event.Skip()

    def build_wishlist(self):
        panel = wx.Panel(self.tabs)
        box = wx.BoxSizer(wx.VERTICAL)
        self.filter = wx.SearchCtrl(panel, name="Filter Wish List", style=wx.TE_PROCESS_ENTER)
        accessible_name(self.filter, "Filter Wish List")
        self.filter.SetDescriptiveText("Filter Wish List")
        self.filter.ShowCancelButton(True)
        self.filter.Bind(wx.EVT_TEXT, lambda event: self.render())
        self.filter.Bind(wx.EVT_SEARCHCTRL_CANCEL_BTN, lambda event: self.filter.Clear())
        box.Add(self.filter, 0, wx.EXPAND | wx.ALL, 10)
        self.list = BookList(panel, name="Audible Wish List", columns=CATALOG_COLUMNS)
        self.filter.Bind(wx.EVT_TEXT_ENTER, self.list.focus_result)
        self.list.Bind(wx.EVT_LIST_ITEM_SELECTED, lambda event: self.update_actions())
        self.list.Bind(wx.EVT_LIST_ITEM_DESELECTED, lambda event: self.update_actions())
        box.Add(self.list, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, 10)
        self.status = wx.StaticText(panel, label=" ", name="Wish list status")
        box.Add(self.status, 0, wx.EXPAND | wx.ALL, 10)
        row = wx.BoxSizer(wx.HORIZONTAL)
        self.add_button = button(panel, "Add Titles…", self.open_catalog)
        self.remove_button = button(panel, "Remove", self.remove)
        self.export_button = button(panel, "Export…", self.export)
        self.refresh_button = button(panel, "Refresh", self.refresh)
        for control in (self.add_button, self.remove_button, self.export_button, self.refresh_button):
            row.Add(control, 0, wx.RIGHT, 6)
        box.Add(row, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 10)
        panel.SetSizer(box)
        return panel

    def build_account(self):
        panel = wx.Panel(self.tabs)
        box = wx.BoxSizer(wx.VERTICAL)
        self.activation_value = wx.TextCtrl(panel, style=wx.TE_READONLY | wx.TE_PASSWORD, name="Activation Bytes")
        add_field(box, panel, "Activation Bytes", self.activation_value)
        row = wx.BoxSizer(wx.HORIZONTAL)
        self.reveal_button = button(panel, "Show", self.toggle_activation)
        self.copy_button = button(panel, "Copy", self.copy_activation)
        self.reload_button = button(panel, "Reload from Audible", lambda: self.fetch_activation(refresh=True))
        for control in (self.reveal_button, self.copy_button, self.reload_button):
            row.Add(control, 0, wx.RIGHT, 6)
        box.Add(row, 0, wx.BOTTOM, 15)
        self.activation_status = wx.StaticText(panel, label=" ")
        box.Add(self.activation_status, 0, wx.EXPAND | wx.BOTTOM, 12)
        self.export_account_button = button(panel, "Export Encrypted Account File…", self.export_account)
        box.Add(self.export_account_button, 0, wx.BOTTOM, 12)
        outer = wx.BoxSizer(wx.VERTICAL)
        outer.Add(box, 1, wx.EXPAND | wx.ALL, 12)
        panel.SetSizer(outer)
        return panel

    def refresh(self, *, preserve_issue=False):
        if not self.signed_in:
            self.status.SetLabel("Sign in to your Audible account to use Audible Tools.")
            for control in (self.add_button, self.remove_button, self.export_button, self.refresh_button,
                            self.reveal_button, self.copy_button, self.reload_button, self.export_account_button):
                control.Disable()
            return
        if not preserve_issue:
            self.wishlist_issue = ""
        self.reveal_button.Enable()
        self.reload_button.Enable()
        self.export_account_button.Enable()
        self.wishlist_busy = True
        self.status.SetLabel("Loading wish list…")
        self.update_actions()

        def loaded(books):
            self.books = browse_books(books, "", {}, "title", False, lambda book: "")
            self.render()

        def failed(error):
            self.wishlist_issue = " ".join(filter(None, [self.wishlist_issue, str(error)]))
            self.render()

        def done():
            self.wishlist_busy = False
            self.update_actions()

        options = self.library.library_options()
        run_async(self, lambda: self.client.run("wishlist", account_id=self.account_id, cancel=self.cancel, options=options),
                  loaded, failure=failed, done=done, cancel=self.cancel)

    def render(self):
        query = self.filter.GetValue().strip()
        books = filter_wishlist(self.books, query)
        self.list.set_books(books, lambda book: "")
        if self.signed_in:
            count = f"{len(books)} of {len(self.books)} titles" if query else f"{len(books)} titles"
            if not books:
                count = "No titles match your search." if query else "Your wish list is empty."
            self.status.SetLabel(self.wishlist_issue or count)
        self.update_actions()

    def update_actions(self):
        available = self.signed_in and not self.wishlist_busy
        self.add_button.Enable(available)
        self.refresh_button.Enable(available)
        self.remove_button.Enable(available and bool(self.list.selected_books()))
        self.export_button.Enable(available and bool(self.books))
        self.copy_button.Enable(self.activation is not None)

    def open_catalog(self):
        if not self.add_button.IsEnabled():
            return
        with CatalogDialog(self, self.client, self.account_id, existing={book["asin"] for book in self.books},
                           options=self.library.library_options()) as dialog:
            dialog.ShowModal()
            if dialog.changed:
                self.wishlist_issue = dialog.issue
                self.refresh(preserve_issue=True)

    def remove(self):
        selected = self.list.selected_books()
        if not selected or not self.remove_button.IsEnabled():
            return
        count = len(selected)
        message = "Remove the selected title from your wish list?" if count == 1 else f"Remove {count} titles from your wish list?"
        if wx.MessageBox(message, "Remove from Wish List", wx.YES_NO | wx.NO_DEFAULT, self) != wx.YES:
            return
        self.wishlist_busy = True
        self.update_actions()

        def removed(failed):
            self.wishlist_issue = per_title_issue(failed, "remove")
            self.refresh(preserve_issue=True)

        def done():
            self.wishlist_busy = False
            self.update_actions()

        options = self.library.library_options()
        run_async(self, lambda: self.client.run("wishlistRemove", account_id=self.account_id,
                  asins=[book["asin"] for book in selected], options=options, cancel=self.cancel), removed,
                  done=done, cancel=self.cancel)

    def export(self, extension=None):
        export_dialog(self, self.books, wishlist=True, title="Export Wish List", extension=extension)

    def toggle_activation(self):
        if self.activation is None:
            self.fetch_activation()
        else:
            self.hide_activation()

    def hide_activation(self):
        self.activation = None
        self.update_activation_display(False)
        self.activation_status.SetLabel("Activation bytes hidden.")

    def update_activation_display(self, visible):
        # Replace the native edit window to keep password masking in the Windows accessibility tree.
        field = self.activation_value
        new_style = wx.TE_READONLY | (0 if visible else wx.TE_PASSWORD)
        replacement = wx.TextCtrl(field.GetParent(), style=new_style, name="Activation Bytes")
        accessible_name(replacement, "Activation Bytes")
        replacement.ChangeValue(self.activation or "")
        field.GetContainingSizer().Replace(field, replacement)
        self.activation_value = replacement
        replacement.MoveBeforeInTabOrder(self.reveal_button)
        field.Destroy()
        self.reveal_button.SetLabel("Hide" if visible else "Show")
        self.account_page.Layout()
        self.update_actions()

    def fetch_activation(self, *, refresh=False):
        if self.activation_busy or not self.signed_in:
            return
        self.activation_busy = True
        self.activation_status.SetLabel("Requesting activation bytes…")
        self.reveal_button.Disable()
        self.reload_button.Disable()
        options = self.library.library_options()

        def load():
            previous = self.client.session(self.account_id)
            result = self.client.run("activation", session=previous, refreshActivation=refresh, options=options, cancel=self.cancel)
            if not self.cancel.is_set():
                self.client.update_session(self.account_id, previous, result["session"])
            return result["activationBytes"]

        def loaded(activation):
            if self.tabs.GetSelection() != 1:
                self.activation_status.SetLabel("Activation bytes hidden.")
                return
            self.activation = activation
            self.activation_status.SetLabel("Activation bytes loaded.")
            self.update_activation_display(True)

        def done():
            self.activation_busy = False
            self.reveal_button.Enable()
            self.reload_button.Enable()

        run_async(self, load, loaded, failure=lambda error: self.activation_status.SetLabel(str(error)), done=done, cancel=self.cancel)

    def copy_activation(self):
        if self.activation is None:
            return
        copied = False
        if wx.TheClipboard.Open():
            try:
                copied = wx.TheClipboard.SetData(wx.TextDataObject(self.activation))
            finally:
                wx.TheClipboard.Close()
        self.activation_status.SetLabel("Activation bytes copied." if copied else "Could not copy activation bytes.")

    def export_account(self):
        if not self.export_account_button.IsEnabled():
            return
        with wx.Dialog(self, title="Export Encrypted Account File") as dialog:
            box = wx.BoxSizer(wx.VERTICAL)
            form = wx.BoxSizer(wx.VERTICAL)
            password = text_field(dialog, "Password", style=wx.TE_PASSWORD)
            confirm = text_field(dialog, "Confirm Password", style=wx.TE_PASSWORD)
            if self.library.frame.demo:
                password.SetValue("password12345")
                confirm.SetValue("password12345")
            add_field(form, dialog, "Password", password)
            add_field(form, dialog, "Confirm Password", confirm)
            warning = wx.StaticText(dialog, label="Keep this file and its password private. Together, they can give access to your Audible account.")
            warning.Wrap(dialog.FromDIP(380))
            form.Add(warning)
            box.Add(form, 0, wx.EXPAND | wx.ALL, 12)
            action = dialog.CreateSeparatedButtonSizer(wx.OK | wx.CANCEL)
            save_button = dialog.FindWindowById(wx.ID_OK)
            save_button.SetLabel("Save Encrypted File…")

            def validate(_event=None):
                value = password.GetValue()
                save_button.Enable(bool(value) and value == confirm.GetValue())

            password.Bind(wx.EVT_TEXT, validate)
            confirm.Bind(wx.EVT_TEXT, validate)
            validate()
            box.Add(action, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)
            dialog.SetSizerAndFit(box)
            dialog.SetSize((dialog.FromDIP(430), dialog.GetSize().height))
            if dialog.ShowModal() != wx.ID_OK:
                return
            password_value = password.GetValue()
            password.Clear()
            confirm.Clear()
        with wx.FileDialog(self, "Save Encrypted Account File", defaultFile="Audible Account.json",
                           wildcard="JSON files (*.json)|*.json", style=wx.FD_SAVE | wx.FD_OVERWRITE_PROMPT) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return
            path = Path(dialog.GetPath())
        self.export_account_button.Disable()

        def save():
            content = self.client.run("exportAuthFile", account_id=self.account_id, password=password_value, cancel=self.cancel)
            if not self.cancel.is_set():
                write_atomic(path, content.encode("utf-8"))

        run_async(self, save, lambda result: self.activation_status.SetLabel("Encrypted account file saved."),
                  done=self.export_account_button.Enable, cancel=self.cancel)


def per_title_issue(failed, action):
    if not failed:
        return ""
    summaries = sorted({str(AudibleError(str(code))) for code in failed.values()})
    return " ".join([f"Audible could not {action} {len(failed)} selected title(s).", *summaries])


class CatalogDialog(wx.Dialog):
    def __init__(self, parent, client, account_id, *, existing=(), options=None):
        super().__init__(parent, title="Add Titles to Wish List", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.client = client
        self.account_id = account_id
        self.existing = set(existing)
        self.options = options or {}
        self.changed = False
        self.issue = ""
        self.searching = False
        self.adding = False
        self.cancel = threading.Event()
        box = wx.BoxSizer(wx.VERTICAL)
        row = wx.BoxSizer(wx.HORIZONTAL)
        self.query = wx.SearchCtrl(self, name="Audiobook title or ASIN", style=wx.TE_PROCESS_ENTER)
        accessible_name(self.query, "Audiobook title or ASIN")
        self.query.SetDescriptiveText("Audiobook title or ASIN")
        self.query.Bind(wx.EVT_TEXT_ENTER, lambda event: self.search())
        self.query.Bind(wx.EVT_SEARCHCTRL_SEARCH_BTN, lambda event: self.search())
        self.query.Bind(wx.EVT_TEXT, lambda event: self.update_actions())
        row.Add(self.query, 1, wx.RIGHT, 6)
        self.search_button = button(self, "Search", self.search)
        row.Add(self.search_button)
        box.Add(row, 0, wx.EXPAND | wx.ALL, 10)
        self.list = BookList(self, name="Search results", columns=CATALOG_COLUMNS)
        self.list.Bind(wx.EVT_LIST_ITEM_SELECTED, lambda event: self.update_actions())
        self.list.Bind(wx.EVT_LIST_ITEM_DESELECTED, lambda event: self.update_actions())
        box.Add(self.list, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, 10)
        self.status = wx.StaticText(self, label=" ", name="Catalogue search status")
        box.Add(self.status, 0, wx.EXPAND | wx.ALL, 10)
        row = wx.BoxSizer(wx.HORIZONTAL)
        close = button(self, "Done", self.Close)
        self.SetEscapeId(close.GetId())
        row.Add(close, 0, wx.RIGHT, 6)
        self.add_button = button(self, "Add to Wish List", self.add)
        row.Add(self.add_button)
        box.Add(row, 0, wx.ALIGN_RIGHT | wx.RIGHT | wx.BOTTOM, 10)
        self.SetSizer(box)
        self.SetMinSize((500, 325))
        self.SetSize((710, 460))
        self.Bind(wx.EVT_CLOSE, self.close)
        shift_control = wx.ACCEL_CTRL | wx.ACCEL_SHIFT
        self._shortcuts = shortcuts(self, [
            (shift_control, ord("F"), self.search),
            (shift_control, ord("A"), self.add),
        ])
        self.query.SetFocus()
        self.update_actions()
        if client.demo:
            self.query.SetValue("Demo")
            self.update_actions()
            self.search()

    def update_actions(self):
        available = not self.searching and not self.adding
        self.search_button.Enable(available and bool(self.query.GetValue().strip()))
        self.add_button.Enable(available and bool(self.list.selected_books()))

    def search(self):
        query = self.query.GetValue().strip()
        if not query or not self.search_button.IsEnabled():
            return
        self.searching = True
        self.list.set_books([], lambda book: "")
        self.status.SetLabel("Searching Audible…")
        self.update_actions()

        def loaded(books):
            books = [book for book in books if book["asin"] not in self.existing]
            self.list.set_books(books, lambda book: "")
            self.status.SetLabel(f"{len(books)} titles found" if books else "No new titles found.")

        def done():
            self.searching = False
            self.update_actions()

        run_async(self, lambda: self.client.run("catalog", account_id=self.account_id, query=query,
                  options=self.options, cancel=self.cancel), loaded, failure=lambda error: self.status.SetLabel(str(error)),
                  done=done, cancel=self.cancel)

    def add(self):
        selected = self.list.selected_books()
        if not selected or not self.add_button.IsEnabled():
            return
        self.adding = True
        self.update_actions()

        def added(failed):
            count = len(selected) - len(failed)
            self.changed |= count > 0
            self.issue = per_title_issue(failed, "add")
            self.existing.update(book["asin"] for book in selected if book["asin"] not in failed)
            self.list.set_books([book for book in self.list.rows if book["asin"] not in self.existing], lambda book: "")
            if not failed:
                finish_dialog(self, wx.ID_OK)
            else:
                self.status.SetLabel(self.issue)

        def done():
            self.adding = False
            self.update_actions()

        run_async(self, lambda: self.client.run("wishlistAdd", account_id=self.account_id,
                  asins=[book["asin"] for book in selected], options=self.options, cancel=self.cancel),
                  added, done=done, cancel=self.cancel)

    def close(self, _event):
        self.cancel.set()
        finish_dialog(self, wx.ID_CLOSE)

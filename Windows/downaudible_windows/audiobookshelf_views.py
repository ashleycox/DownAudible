"""Native settings and upload queue controls for Audiobookshelf."""

from copy import deepcopy
from threading import Thread

import wx

from .audiobookshelf import (
    ShelfClient,
    ShelfError,
    ShelfFolder,
    ShelfLibrary,
    UploadTarget,
    archive_upload,
    normalize_server,
    receipt_index,
    server_origin,
    stored_token,
    update_token,
    validate_token,
)
from .library_catalog import profile_id
from .report_list import report_list


class ShelfSettings:
    def __init__(self, form):
        self.form, self.frame = form, form.frame
        self.settings = form.settings["audiobookshelf"]
        self.connected_server = self.settings.get("server", "")
        self.libraries = ()
        self.removed_token = False

        form.heading("Audiobookshelf")
        form.note("Connect to a book library on your Audiobookshelf server. "
                  "DownAudible stores the API token in your Windows profile. "
                  "Use HTTPS for remote servers.")
        self.server = form.row(wx.StaticText(form, label="Server URL"), wx.TextCtrl(form, value=self.connected_server))
        self.token = form.row(wx.StaticText(form, label="API token"), wx.TextCtrl(form, style=wx.TE_PASSWORD))
        self.token.SetToolTip("Enter an API token for a user with upload permission. "
                              "Leave it blank to keep the token already saved for this server.")
        self.forget = form.button("Forget saved token", self.forget_token)
        self.connect = form.button("Connect…", self.load_libraries)
        self.library = form.row(wx.StaticText(form, label="Library"), wx.Choice(form))
        self.folder = form.row(wx.StaticText(form, label="Folder"), wx.Choice(form))
        self.automatic = wx.CheckBox(form, label="Upload new downloads automatically")
        self.automatic.SetValue(bool(self.settings.get("auto_upload")))
        form.add_row(self.automatic)
        self.include_pdf = wx.CheckBox(form, label="Include companion PDFs")
        self.include_pdf.SetValue(bool(self.settings.get("include_pdf")))
        form.add_row(self.include_pdf)
        self.status = form.note("DownAudible uploads saved M4B, M4A, or MP3 files and available cover art.")
        self.status.SetName("Audiobookshelf connection status")

        try:
            target = UploadTarget.from_settings(self.settings)
        except ShelfError:
            target = None
        if target:
            old_folder = ShelfFolder(target.folder_id, target.folder_name or "Selected folder")
            self.libraries = (ShelfLibrary(target.library_id, target.library_name or "Selected library", (old_folder,)),)
        self.library.Bind(wx.EVT_CHOICE, lambda event: self.reload_folders())
        self.server.Bind(wx.EVT_TEXT, self.server_changed)
        self.reload_libraries(self.settings.get("library_id"), self.settings.get("folder_id"))

    def set_status(self, value):
        self.status.SetLabel(value)
        for index, (control, _message) in enumerate(self.form.notes):
            if control is self.status:
                self.form.notes[index] = (control, value)
                break
        self.form.content_width = None
        self.form.fit_rows()

    def forget_token(self):
        self.removed_token = True
        self.token.ChangeValue("")
        self.automatic.SetValue(False)
        self.set_status("The saved token will be removed when you save these settings.")

    def server_changed(self, event):
        try:
            changed = normalize_server(self.server.GetValue()) != self.connected_server
        except ShelfError:
            changed = True
        if changed:
            self.libraries = ()
            self.reload_libraries()
        event.Skip()

    def reload_libraries(self, matching=None, matching_folder=None):
        self.library.Set([library.name for library in self.libraries])
        if self.libraries:
            self.library.SetSelection(next((i for i, library in enumerate(self.libraries) if library.id == matching), 0))
        self.reload_folders(matching_folder)

    def reload_folders(self, matching=None):
        index = self.library.GetSelection()
        folders = self.libraries[index].folders if index != wx.NOT_FOUND else ()
        self.folder.Set([folder.path for folder in folders])
        if folders:
            self.folder.SetSelection(next((i for i, folder in enumerate(folders) if folder.id == matching), 0))

    def current_token(self, server):
        typed = self.token.GetValue().strip()
        if typed:
            return validate_token(typed)
        if self.removed_token or not self.connected_server:
            return ""
        if server_origin(server) != server_origin(self.settings.get("server") or self.connected_server):
            return ""
        return stored_token(self.frame.library.client, server)

    def load_libraries(self):
        try:
            server = normalize_server(self.server.GetValue())
            token = self.current_token(server)
            if not token:
                raise ShelfError("Enter the API token for this Audiobookshelf server.")
        except ShelfError as error:
            self.set_status(str(error))
            return
        if self.frame.demo:
            demo = ShelfLibrary("example", "Audiobooks", (ShelfFolder("folder", "/audiobooks"),))
            self.loaded(server, (demo,), None)
            return
        self.connect.Disable()
        self.set_status("Connecting to Audiobookshelf…")

        def load():
            try:
                libraries = ShelfClient(server, token, timeout=15).libraries()
                error = None
            except ShelfError as caught:
                libraries, error = (), str(caught)
            wx.CallAfter(self.loaded, server, libraries, error)

        Thread(target=load, daemon=True, name="Connect to Audiobookshelf").start()

    def loaded(self, server, libraries, error):
        if not self.form or self.form.IsBeingDeleted():
            return
        self.connect.Enable()
        try:
            if normalize_server(self.server.GetValue()) != server:
                return
        except ShelfError:
            return
        if error:
            self.set_status(error)
            return
        self.connected_server, self.libraries = server, libraries
        self.reload_libraries(self.settings.get("library_id"), self.settings.get("folder_id"))
        self.set_status("Choose a book library and folder." if libraries else
                        "This token has no access to an Audiobookshelf book library with a folder.")

    def save(self, vault):
        server = self.server.GetValue().strip()
        server = normalize_server(server) if server else ""
        token = self.current_token(server) if server else ""
        library = folder = None
        if server and self.connected_server == server and self.library.GetSelection() != wx.NOT_FOUND:
            library = self.libraries[self.library.GetSelection()]
            if self.folder.GetSelection() != wx.NOT_FOUND:
                folder = library.folders[self.folder.GetSelection()]
        if self.automatic.IsChecked() and not (token and library and folder):
            raise ShelfError("Connect to an Audiobookshelf library and folder before turning on automatic uploads.")
        typed = self.token.GetValue().strip()
        client = self.frame.library.client
        if typed and server:
            vault.enter_context(update_token(client, server, token))
        elif self.removed_token or (not server and self.settings.get("server")):
            vault.enter_context(update_token(client, server, ""))
        self.settings.update(
            server=server, library_id=library.id if library else "", folder_id=folder.id if folder else "",
            library_name=library.name if library else "", folder_name=folder.path if folder else "",
            auto_upload=self.automatic.IsChecked(), include_pdf=self.include_pdf.IsChecked(),
        )


class ShelfUploadsDialog(wx.Dialog):
    def __init__(self, frame, *, position):
        super().__init__(frame, title="Audiobookshelf Uploads", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.frame = frame
        self.queue = frame.audiobookshelf
        self.rows = ()
        self.working = False
        self.last_status = ""
        layout = wx.BoxSizer(wx.VERTICAL)
        self.note = wx.StaticText(self, label="Saved audio stays on this PC.")
        layout.Add(self.note, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        self.list = report_list(self, "Audiobookshelf uploads", (
            ("Book", 190), ("Status", 140), ("Details", 220),
        ), fill=2, style=wx.LC_HRULES)
        layout.Add(self.list, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, self.FromDIP(12))
        actions = wx.BoxSizer(wx.HORIZONTAL)
        for label, action in (
            ("Queue Selected Books…", lambda: self.queue_saved(selected=True)),
            ("Queue All Saved Books…", lambda: self.queue_saved(selected=False)),
            ("Retry Failed Uploads", self.retry),
        ):
            button = wx.Button(self, label=label)
            button.Bind(wx.EVT_BUTTON, lambda event, run=action: run())
            actions.Add(button, 0, wx.ALL, self.FromDIP(4))
        layout.Add(actions, 0, wx.LEFT | wx.RIGHT | wx.TOP, self.FromDIP(8))
        layout.Add(self.CreateStdDialogButtonSizer(wx.CLOSE), 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        self.SetSizer(layout)
        self.Bind(wx.EVT_BUTTON, lambda event: self.EndModal(wx.ID_CLOSE), id=wx.ID_CLOSE)
        self.timer = wx.Timer(self)
        self.Bind(wx.EVT_TIMER, self.refresh, self.timer)
        self.Bind(wx.EVT_CLOSE, lambda event: self.EndModal(wx.ID_CLOSE))
        position(self, frame, (785, 500), (510, 320))
        self.refresh()
        self.timer.Start(500)

    def refresh(self, _event=None):
        rows = self.queue.snapshot()
        if rows == self.rows:
            return
        selected = self.selection()
        self.rows = rows
        self.list.Freeze()
        try:
            self.list.DeleteAllItems()
            for index, row in enumerate(rows):
                self.list.InsertItem(index, row["book"]["title"])
                self.list.SetItem(index, 1, row["status"])
                detail = row["detail"]
                if self.queue.target is None or row["target"]["server"] != self.queue.target.server:
                    detail = "Connect to the original destination to resume."
                self.list.SetItem(index, 2, detail)
                if row["id"] in selected:
                    self.list.Select(index)
        finally:
            self.list.Thaw()

    def selection(self):
        row, selected = self.list.GetFirstSelected(), set()
        while 0 <= row < len(self.rows):
            selected.add(self.rows[row]["id"])
            row = self.list.GetNextSelected(row)
        return selected

    def retry(self):
        try:
            count = self.queue.retry(self.selection())
            self.note.SetLabel(f"Queued {count} failed upload(s)." if count else "No failed uploads to retry for this destination.")
        except ShelfError as error:
            self.note.SetLabel(str(error))
        self.refresh()

    def queue_saved(self, *, selected):
        if self.working:
            return
        settings = self.frame.settings.get("audiobookshelf", {})
        target = UploadTarget.from_settings(settings)
        if not target or not self.queue.token:
            self.note.SetLabel("Connect to a book library and folder in Settings > Audiobookshelf first.")
            return
        books = self.frame.library.selected_books() if selected else self.frame.library.books
        if not books:
            self.note.SetLabel("Select books in the Library first." if selected else "Open an Audible library first.")
            return
        account = self.frame.settings.get("audible_account")
        book_rows = [(book, profile_id(book, account), tuple(self.frame.match_paths(book))) for book in deepcopy(books)]
        receipts = self.frame.data_dir / "Receipts"
        archive = self.frame.selected_archive_root()
        include_pdf = bool(settings.get("include_pdf"))
        with wx.MessageDialog(
            self, f"Look for saved audio for {len(books):,} book(s) and send it to {target.library_name or 'the selected library'}?",
            "Queue Audiobookshelf Uploads", wx.YES_NO | wx.NO_DEFAULT | wx.ICON_QUESTION,
        ) as confirmation:
            if confirmation.ShowModal() != wx.ID_YES:
                return
        self.working = True
        self.note.SetLabel("Checking saved audio…")

        def prepare():
            prepared, missing = [], 0
            indexes = {owner: receipt_index(receipts, owner, archive) for owner in {owner for _, owner, _ in book_rows}}
            for book, owner, matches in book_rows:
                try:
                    prepared.append(archive_upload(book, indexes[owner].get(book["asin"], ()), archive,
                                                   matches=matches, include_pdf=include_pdf))
                except (OSError, ShelfError):
                    missing += 1
            try:
                queued = self.queue.enqueue(prepared, expected_target=target)
                result = f"Queued {queued:,} upload(s). {missing:,} book(s) had no complete playable audio."
            except ShelfError as error:
                result = str(error)
            wx.CallAfter(self.prepared, result)

        Thread(target=prepare, daemon=True, name="Find saved audiobooks for upload").start()

    def prepared(self, message):
        if not self or self.IsBeingDeleted():
            return
        self.working = False
        self.note.SetLabel(message)
        self.refresh()

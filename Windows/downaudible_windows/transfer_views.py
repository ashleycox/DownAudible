"""Download options and the Downloads workspace."""

from copy import deepcopy
from datetime import datetime
from functools import partial
from pathlib import Path

import wx

from .archive import ArchiveError, ArchiveLayout
from .media import AUDIO_FORMATS, valid_activation_bytes
from .queue import RETRYABLE, accepts_activation_bytes
from .report_list import report_list
from .settings_views import DOWNLOAD_CHOICES, Form, labeled, place_dialog
from .state import OPEN_AFTER_SAVING, native_folder_template


def selected_rows(control):
    row = control.GetFirstSelected()
    while row >= 0:
        yield row
        row = control.GetNextSelected(row)


def available_outputs(jobs, *, player=False):
    paths = {}
    for job in jobs:
        for value in job["files"]:
            path = Path(value)
            if not path.is_file() or (player and path.suffix.lstrip(".").casefold() not in AUDIO_FORMATS):
                continue
            paths[path] = None
            if player:
                break
    return list(paths)


def download_example_paths(settings, book, options, source_format=None):
    layout = ArchiveLayout.from_settings({**settings, "folder_template": options["folder_template"]},
                                         options["destination"])
    if not layout.is_valid:
        raise ArchiveError("Check the folder and filename templates.")
    conversion = settings["conversion"]
    requested_format = "aaxc" if settings["api"]["format"] == "aaxcOnly" else "aax"
    paths = []
    if options["downloadAudio"]:
        original_format = source_format or requested_format
        if not options["convert"] or options["keepOriginal"]:
            if layout.keep_aax_filename and original_format == "aax" and source_format is None:
                paths.append(str(layout.directory(book, original_format)))
                paths.append("Uses Audible’s AAX filename when available.")
            else:
                paths.append(str(layout.destination(book, original_format)))
        if options["convert"]:
            chapter = (1, "First Chapter") if conversion["chapter_mode"] == "separate" else ()
            paths.append(str(layout.destination(book, conversion["format"], *chapter)))
    elif any(options[key] for key in ("downloadPDF", "downloadCover", "downloadChapters", "downloadAnnotations")):
        paths.append(str(layout.directory(book, source_format or "extras")))
    return paths


class DownloadDialog(wx.Dialog):
    def __init__(self, frame, books, options=None, title="Download As"):
        super().__init__(frame, title=title, style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.settings = frame.settings
        self.book = books[0]
        self.options = dict(deepcopy(frame.settings["download"]), **(options or {}))
        self.options.setdefault("destination", frame.settings["archive_root"])
        self.options.setdefault("folder_template", frame.settings["folder_template"])
        self.restart = self.options.get("restart", False)
        if self.restart:
            self.options["downloadAudio"] = True
        files = [] if self.restart else frame.files_for_book(self.book)
        self.source_format = next((path.suffix.lstrip(".").casefold() for path in files if path.is_file()), None)
        self.form = Form(self)
        name = books[0]["title"] if len(books) == 1 else f"{len(books)} selected books"
        self.form.heading(name)
        if self.restart:
            self.form.note("Restart discards saved partial audio and downloads the selected books from the beginning.")
        checks = {}
        for key, label in DOWNLOAD_CHOICES:
            if key == "convert":
                label = f"Convert to {frame.settings['conversion']['format'].upper()}"
            checks[key] = self.form.check(self.options, key, label)
            checks[key].Bind(wx.EVT_CHECKBOX, self._update_preview)
        self.download_audio = checks["downloadAudio"]
        self.convert = checks["convert"]
        self.keep_original = checks["keepOriginal"]
        self.download_audio.Enable(not self.restart)
        if self.restart:
            destination = wx.TextCtrl(self.form, value=self.options["destination"], style=wx.TE_READONLY)
            self.form.row(wx.StaticText(self.form, label="Save to"), destination)
        else:
            destination = self.form.choose_path(self.options, "destination", "Save to", folder=True)
            destination.Bind(wx.EVT_TEXT, self._update_preview)
        template = self.form.text(self.options, "folder_template", "Folder template",
                                  value=native_folder_template(self.options["folder_template"]),
                                  getter=native_folder_template)
        template.Bind(wx.EVT_TEXT, self._update_preview)
        self.form.note("Use fields such as {format}, {author}, {title}, and {asin}. Separate folders with a backslash.")
        self.form.choice(self.options, "open_after_saving", "Open after saving", OPEN_AFTER_SAVING)
        self.form.heading("Example paths")
        self.preview = labeled(wx.TextCtrl(self.form, style=wx.TE_MULTILINE | wx.TE_READONLY,
                                           size=(-1, self.FromDIP(80))), "Example paths")
        self.form.add_row(self.preview, wx.EXPAND)
        self.form.complete()
        layout = wx.BoxSizer(wx.VERTICAL)
        layout.Add(self.form, 1, wx.EXPAND | wx.ALL, self.FromDIP(6))
        buttons = self.CreateStdDialogButtonSizer(wx.OK | wx.CANCEL)
        self.primary = self.FindWindow(wx.ID_OK)
        self.primary.SetLabel("Restart" if self.restart else "Download")
        self.primary.SetDefault()
        layout.Add(buttons, 0, wx.EXPAND | wx.ALL, self.FromDIP(10))
        self.SetSizer(layout)
        place_dialog(self, frame, preferred=(700, 560), minimum=(470, 370))
        self.Bind(wx.EVT_BUTTON, self._apply, id=wx.ID_OK)
        self._update_preview()

    def _preview_text(self):
        if not self.options["destination"].strip():
            raise ValueError("Choose where to save the files.")
        paths = download_example_paths(self.settings, self.book, self.options, self.source_format)
        if not paths:
            raise ValueError("Choose audio or at least one companion file.")
        return "\n".join(paths)

    def _update_preview(self, event=None):
        self.form.apply()
        self.convert.Enable(self.options["downloadAudio"])
        self.keep_original.Enable(self.options["downloadAudio"] and self.options["convert"])
        try:
            text = self._preview_text()
        except (OSError, ValueError) as error:
            self.preview.ChangeValue(str(error))
            self.primary.Disable()
        else:
            self.preview.ChangeValue(text)
            self.primary.Enable()

    def _apply(self, event):
        self.form.apply()
        try:
            self._preview_text()
        except (OSError, ValueError) as error:
            wx.MessageBox(str(error), "Check Download Options", wx.OK | wx.ICON_ERROR, self)
        else:
            self.EndModal(wx.ID_OK)


class TransfersPanel(wx.Panel):
    def __init__(self, parent, frame):
        super().__init__(parent)
        self.frame = frame
        self.batches = []
        self.rows = []
        self.active_batch = None
        self.layout = wx.BoxSizer(wx.VERTICAL)
        self.SetSizer(self.layout)

        title = wx.StaticText(self, label="Downloads")
        title.SetFont(title.GetFont().Scale(1.4).Bold())
        margin = self.FromDIP(12)
        gap = self.FromDIP(8)
        self.layout.Add(title, 0, wx.LEFT | wx.TOP, margin)

        toolbar = wx.BoxSizer(wx.HORIZONTAL)
        toolbar.Add(wx.StaticText(self, label="Show"), 0, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, gap)
        self.show = wx.Choice(self)
        self.show.SetName("Show batch")
        self.show.Bind(wx.EVT_CHOICE, self._batch_selected)
        toolbar.Add(self.show, 1, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, gap)
        self.actions = wx.Button(self, label="Download &Actions")
        self.actions.Bind(wx.EVT_BUTTON, lambda event: self.show_actions())
        toolbar.Add(self.actions, 0, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, gap)
        self.cancel_button = self._button(toolbar, "Cancel Batch", lambda: self.frame.queue.cancel())
        self.retry_button = self._button(toolbar, "Retry Incomplete", lambda: self.retry())
        self.show.SetToolTip("Choose the current transfer batch or an earlier batch.")
        self.actions.SetToolTip("Open commands for the selected transfers and saved files.")
        self.cancel_button.SetToolTip("Stop the current batch and keep its saved progress for a retry.")
        self.retry_button.SetToolTip("Retry failed or interrupted jobs in the displayed batch.")
        self.layout.Add(toolbar, 0, wx.EXPAND | wx.ALL, margin)

        self.list = report_list(self, "Transfers", (
            ("Title", 165), ("Job", 85), ("Status", 105), ("Progress", 80), ("Details", 215),
        ), fill=4, style=wx.LC_HRULES)
        self.list.Bind(wx.EVT_LIST_ITEM_RIGHT_CLICK, self._right_click)
        self.list.Bind(wx.EVT_CONTEXT_MENU, self._keyboard_context)
        self.list.Bind(wx.EVT_LIST_ITEM_ACTIVATED, lambda event: self.reveal())
        self.list.Bind(wx.EVT_KEY_DOWN, self._key)
        self.layout.Add(self.list, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, margin)
        self.gauge = wx.Gauge(self, range=100)
        self.gauge.SetName("Batch progress")
        self.layout.Add(self.gauge, 0, wx.EXPAND | wx.TOP | wx.LEFT | wx.RIGHT, margin)
        self.summary = wx.StaticText(self, label="No transfers yet.")
        self.layout.Add(self.summary, 0, wx.ALL, margin)

    def _button(self, toolbar, label, callback):
        button = wx.Button(self, label=label)
        button.Bind(wx.EVT_BUTTON, lambda event: self.frame.guard(callback))
        toolbar.Add(button, 0, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, self.FromDIP(8))
        return button

    def refresh(self, state=None):
        state = state or self.frame.queue.snapshot()
        self.batches = [state["current"], *state["history"]]
        labels = ["Current Batch"]
        for batch in state["history"]:
            date = datetime.fromisoformat(batch["date"]).astimezone()
            labels.append(f"{date:%d %b %Y, %H:%M} · {len(batch['jobs'])} jobs")
        if list(self.show.GetStrings()) != labels:
            self.show.Set(labels)
        selection = next((index for index, batch in enumerate(self.batches)
                          if batch and batch["id"] == self.active_batch), 0)
        self.show.SetSelection(selection)
        self._display(self.batches[selection])

    def _batch_selected(self, event):
        index = self.show.GetSelection()
        batch = self.batches[index]
        self.active_batch = batch["id"] if batch and index else None
        self._display(batch)
        self.frame.refresh_transfer_menu()

    def _display(self, batch):
        jobs = batch["jobs"] if batch else []
        old_ids = [job["id"] for job in self.rows]
        ids = [job["id"] for job in jobs]
        if old_ids != ids:
            selected = {job["id"] for job in self.selected()}
            self.list.DeleteAllItems()
            for index, job in enumerate(jobs):
                self.list.InsertItem(index, job["title"])
                if job["id"] in selected:
                    self.list.Select(index)
        self.rows = jobs
        show_progress = self.frame.settings["show_progress"]
        for index, job in enumerate(jobs):
            progress = job.get("progress")
            columns = (job["kind"], job["status"], f"{round(progress * 100)}%" if progress is not None and show_progress else "",
                       job["detail"])
            for column, value in enumerate(columns, 1):
                if self.list.GetItemText(index, column) != value:
                    self.list.SetItem(index, column, value)
        finished = sum(job["status"] not in {"Running", "Waiting"} for job in jobs)
        active = sum((job.get("progress") or 0) for job in jobs if job["status"] == "Running")
        self.gauge.SetValue(round((finished + active) * 100 / len(jobs)) if jobs else 0)
        self.gauge.Show(bool(jobs) and show_progress)
        self.summary.SetLabel(f"{finished} of {len(jobs)} jobs finished" if jobs else "No transfers yet.")
        viewing_current = self.show.GetSelection() == 0
        self.cancel_button.Enable(viewing_current and any(job["status"] in {"Running", "Waiting"} for job in jobs))
        self.retry_button.Enable(not self.frame.queue.pending and any(job["status"] in RETRYABLE for job in jobs))
        self.Layout()

    def selected(self):
        return [self.rows[row] for row in selected_rows(self.list) if row < len(self.rows)]

    def shown_batch(self):
        index = self.show.GetSelection()
        return self.batches[index] if 0 <= index < len(self.batches) else None

    def can_restart(self, job, batch):
        return (job["status"] in RETRYABLE and job["kind"] == "Download"
                and self.frame.runner.has_partial(job, batch["settings"]))

    def _right_click(self, event):
        index = event.GetIndex()
        if index >= 0 and not self.list.IsSelected(index):
            for row in list(selected_rows(self.list)):
                self.list.Select(row, False)
            self.list.Select(index)
            self.list.Focus(index)
        self.show_actions()

    def _keyboard_context(self, event):
        if event.GetPosition() == wx.DefaultPosition:
            self.show_actions()
        else:
            event.Skip()

    def populate_actions(self, menu, *, shortcut_labels=True):
        selected = self.selected()
        current = self.show.GetSelection() == 0
        active = self.frame.queue.pending
        batch = self.shown_batch()

        def action(label, run, enabled=True):
            if not shortcut_labels:
                label = label.partition("\t")[0]
            item = menu.Append(wx.ID_ANY, label)
            item.Enable(bool(enabled))
            menu.Bind(wx.EVT_MENU, lambda event: self.frame.guard(run), item)

        action("Cancel Selected Transfers", self.cancel_selected,
               current and any(job["status"] in {"Running", "Waiting"} for job in selected))
        action("Retry Selected Transfers\tCtrl+Shift+R", lambda: self.retry(selected=True),
               not active and any(job["status"] in RETRYABLE for job in selected))
        action("Retry with Activation Bytes…", self.retry_with_activation,
               not active and any(self.can_retry_with_activation(job) for job in selected))
        action("Restart Selected Downloads…\tCtrl+Shift+T", lambda: self.retry(selected=True, restart=True),
               not active and batch and any(self.can_restart(job, batch) for job in selected))
        action("Restart Incomplete Downloads…", lambda: self.retry(restart=True),
               not active and batch and any(self.can_restart(job, batch) for job in self.rows))
        menu.AppendSeparator()
        action("Show Output in File Explorer\tCtrl+Shift+F", self.reveal, available_outputs(selected))
        action("Open in Player", self.open_audio, available_outputs(selected, player=True))
        action("Show Partial Files\tCtrl+Shift+P", self.reveal_partial,
               batch and any(self.frame.runner.has_partial(job, batch["settings"]) for job in selected))
        action("Copy Errors\tCtrl+Shift+E", self.copy_errors, any(job["status"] in {"Failed", "Warning"} for job in selected))
        menu.AppendSeparator()
        action("Clear Completed", self.clear_completed, not active and any(job["status"] == "Completed" for job in self.rows))
        action("Remove from List\tDelete", self.remove_selected, not active and selected)

    def show_actions(self):
        menu = wx.Menu()
        self.populate_actions(menu)
        self.PopupMenu(menu)
        menu.Destroy()

    def _key(self, event):
        if event.GetKeyCode() in (wx.WXK_DELETE, wx.WXK_BACK):
            if not self.frame.queue.pending:
                self.frame.guard(self.remove_selected)
        elif event.ControlDown() and event.ShiftDown() and not event.AltDown():
            handlers = {
                ord("R"): lambda: self.retry(selected=True),
                ord("T"): lambda: self.retry(selected=True, restart=True),
                ord("F"): self.reveal, ord("P"): self.reveal_partial, ord("E"): self.copy_errors,
            }
            handler = handlers.get(event.GetKeyCode())
            if handler:
                self.frame.guard(handler)
            else:
                event.Skip()
        else:
            event.Skip()

    def cancel_selected(self):
        identifiers = {job["id"] for job in self.selected()}
        if identifiers:
            self.frame.queue.cancel(identifiers)

    def remove_selected(self):
        identifiers = {job["id"] for job in self.selected()}
        batch = self.shown_batch()
        if identifiers and batch:
            self.frame.queue.remove(identifiers, batch_id=batch["id"])

    def clear_completed(self):
        if batch := self.shown_batch():
            self.frame.queue.remove(completed_only=True, batch_id=batch["id"])

    @staticmethod
    def can_retry_with_activation(job):
        return job["status"] in RETRYABLE and accepts_activation_bytes(job)

    def activation_dialog(self):
        message = ("Enter the eight hexadecimal activation characters for the selected AAX audio.\n"
                   "Leave blank to use the Audible account saved with each job.")
        return wx.PasswordEntryDialog(self, message, "Retry with Activation Bytes")

    def retry_with_activation(self):
        batch = self.shown_batch()
        identifiers = {job["id"] for job in self.selected() if self.can_retry_with_activation(job)}
        if not batch or not identifiers:
            return
        with self.activation_dialog() as dialog:
            while dialog.ShowModal() == wx.ID_OK:
                value = dialog.GetValue().strip()
                if not value or valid_activation_bytes(value):
                    prepare_activation = partial(self.frame.runner.retry_activation_reference, value)
                    break
                self.frame.error("Enter eight hexadecimal activation characters or leave the field blank.",
                                 "Check the Activation Bytes")
            else:
                return
        self.retry_batch(batch["id"], identifiers, prepare_activation=prepare_activation)

    def retry(self, *, selected=False, restart=False):
        batch = self.shown_batch()
        if batch is None:
            return
        identifiers = {job["id"] for job in self.selected()} if selected else None
        if selected and not identifiers:
            return
        if restart:
            jobs = self.selected() if selected else batch["jobs"]
            identifiers = {job["id"] for job in jobs if self.can_restart(job, batch)}
            if not identifiers:
                self.frame.set_status("No partial audio is available to restart in this batch.")
                return
            with wx.MessageDialog(self, "Restart these downloads from the beginning? Partial audio will be removed.",
                                  "Restart Incomplete Downloads", wx.YES_NO | wx.NO_DEFAULT | wx.ICON_QUESTION) as dialog:
                if dialog.ShowModal() != wx.ID_YES:
                    return
        self.retry_batch(batch["id"], identifiers, restart=restart)

    def retry_batch(self, batch_id, identifiers, **options):
        if self.frame.queue.retry(batch_id, identifiers, **options):
            self.active_batch = None
            self.refresh()

    def reveal(self):
        paths = available_outputs(self.selected())
        if not paths:
            self.frame.set_status("No saved files are available for the selected jobs.")
        for path in paths:
            self.frame.show_file(path)

    def open_audio(self):
        for path in available_outputs(self.selected(), player=True):
            self.frame.open_file(path)

    def reveal_partial(self):
        batch = self.shown_batch()
        if not batch:
            return
        settings = batch["settings"]
        folders = dict.fromkeys(self.frame.runner.stage_for(job, settings).path
                                for job in self.selected() if self.frame.runner.has_partial(job, settings))
        if not folders:
            self.frame.set_status("No partial files are available for the selected jobs.")
        for folder in folders:
            self.frame.open_file(folder)

    def copy_errors(self):
        text = "\n".join(f"{job['title']}: {job['detail']}" for job in self.selected() if job["status"] in {"Failed", "Warning"})
        if text and wx.TheClipboard.Open():
            try:
                wx.TheClipboard.SetData(wx.TextDataObject(text))
            finally:
                wx.TheClipboard.Close()

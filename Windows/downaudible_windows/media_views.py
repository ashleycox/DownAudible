from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import asdict, replace
from pathlib import Path
from threading import Event, Thread

import wx

from .archive import ArchiveError, ArchiveLayout, verify_archive
from .cue import supports_cue, write_cue_sheet
from .library import natural_key
from .media import (
    AUDIO_FORMATS,
    ConversionOptions,
    LocalAudio,
    MediaCancelled,
    MediaInput,
    source_revision,
    valid_activation_bytes,
)
from .report_list import report_list
from .settings_views import save_settings_changes
from .state import api_options

AUDIO_WILDCARD = 'Audio files (*.aax;*.aaxc;*.aa;*.m4b;*.m4a;*.mp3)|*.aax;*.aaxc;*.aa;*.m4b;*.m4a;*.mp3|All files (*.*)|*.*'
PLAYER_FORMATS = frozenset({'m4a', 'm4b', 'mp3'})
REPAIR_LABELS = {'missing': 'Missing audio', 'incomplete': 'Incomplete audio', 'unreadable': 'Unreadable audio'}


def _select(control):
    result = []
    index = control.GetFirstSelected()
    while index != -1:
        result.append(index)
        index = control.GetNextSelected(index)
    return result


def _duration(milliseconds: int) -> str:
    seconds = max(0, round(milliseconds / 1000))
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f'{hours}:{minutes:02d}:{seconds:02d}' if hours else f'{minutes}:{seconds:02d}'


def _local_book_inputs(items):
    by_path = {}
    for item in items:
        path = item.path if isinstance(item, LocalAudio) else Path(item)
        by_path.setdefault(path, item)
    paths = sorted(by_path, key=lambda path: (natural_key(path.name), str(path)))
    first = by_path[paths[0]] if paths else None
    if not isinstance(first, LocalAudio):
        return paths, None
    metadata = {**first.metadata, 'title': first.title, 'author': first.author, 'asin': first.asin}
    if len(paths) > 1:
        metadata['title'] = first.collection or first.title
        if first.collection_author:
            metadata['author'] = metadata['authors'] = first.collection_author
    return paths, metadata


def _button(parent, sizer, label, callback):
    button = wx.Button(parent, label=label)
    button.Bind(wx.EVT_BUTTON, lambda _event: callback())
    sizer.Add(button, 0, wx.RIGHT, parent.FromDIP(6))
    return button


def _tell(parent, message, title='DownAudible'):
    wx.MessageBox(str(message), title, wx.OK | wx.ICON_WARNING, parent)


class _Work:
    def __init__(self, owner):
        self.owner = owner
        self.cancel = Event()
        self.running = False
        self.closed = False
        owner.Bind(wx.EVT_WINDOW_DESTROY, self._destroy)

    def _destroy(self, event):
        if event.GetEventObject() == self.owner:
            self.closed = True
            self.cancel.set()
        event.Skip()

    def run(self, function, success, failure, progress=None):
        if self.running:
            return
        self.running = True
        self.cancel = Event()

        def post(callback, *args):
            def update():
                if not self.closed:
                    callback(*args)
            wx.CallAfter(update)

        def finish(callback, value):
            self.running = False
            callback(value)

        def perform():
            try:
                value = function(self.cancel, lambda value: post(progress, value) if progress else None)
            except Exception as error:  # noqa: BLE001 - finish the UI task after any worker failure
                post(finish, failure, error)
            else:
                post(finish, success, value)

        Thread(target=perform, daemon=True, name='DownAudible media operation').start()


class _DropTarget(wx.FileDropTarget):
    def __init__(self, add):
        super().__init__()
        self.add = add

    def OnDropFiles(self, _x, _y, files):
        self.add(files)
        return True


class ConverterPanel(wx.Panel):
    def __init__(self, parent, frame):
        super().__init__(parent, name='Convert Files')
        self.frame = frame
        self.files = []
        self.work = _Work(self)
        self.sort_column = 0
        self.sort_descending = False
        self.rebuilding = False
        layout = wx.BoxSizer(wx.VERTICAL)
        toolbar = wx.BoxSizer(wx.HORIZONTAL)
        self.files_button = _button(self, toolbar, 'Add &Files…', self.add_files)
        self.folder_button = _button(self, toolbar, 'Add F&older…', self.add_folder)
        self.remove_button = _button(self, toolbar, '&Remove from List', self.remove)
        self.clear_button = _button(self, toolbar, 'C&lear List', self.clear)
        self.edit_button = _button(self, toolbar, '&Edit Book…', self.edit)
        self.files_button.SetToolTip('Add audiobook files from your computer to the conversion list.')
        self.folder_button.SetToolTip('Find audiobook files in a folder and its subfolders.')
        self.remove_button.SetToolTip('Remove the selected rows from the conversion list.')
        self.clear_button.SetToolTip('Clear the conversion list.')
        self.edit_button.SetToolTip('Preview and choose which sections to keep in a new M4B.')
        layout.Add(toolbar, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))

        self.list = report_list(self, 'Audio files', (
            ('Title', 190), ('Author', 140), ('Format', 72), ('Duration', 82), ('Source', 180),
        ), fill=4, style=wx.LC_HRULES)
        self.list.SetDropTarget(_DropTarget(self.add_paths))
        self.list.Bind(wx.EVT_LIST_ITEM_SELECTED, self.refresh_actions)
        self.list.Bind(wx.EVT_LIST_ITEM_DESELECTED, self.refresh_actions)
        self.list.Bind(wx.EVT_LIST_KEY_DOWN, self._key)
        self.list.Bind(wx.EVT_LIST_COL_CLICK, self._sort)
        self.list.Bind(wx.EVT_CONTEXT_MENU, self._context)
        layout.Add(self.list, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, self.FromDIP(12))

        self.status = wx.StaticText(self, label='Add files or a folder to convert audio.')
        layout.Add(self.status, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        fields = wx.FlexGridSizer(cols=3, vgap=self.FromDIP(8), hgap=self.FromDIP(8))
        fields.AddGrowableCol(1)
        target_label = wx.StaticText(self, label='Destination')
        self.destination = wx.TextCtrl(self, value=str(frame.settings.get('archive_root') or ''),
                                       style=wx.TE_READONLY, name='Destination folder')
        fields.Add(target_label, 0, wx.ALIGN_CENTER_VERTICAL)
        fields.Add(self.destination, 1, wx.EXPAND)
        choose = wx.Button(self, label='&Choose…')
        choose.SetToolTip('Choose the folder for converted audiobooks.')
        choose.Bind(wx.EVT_BUTTON, lambda _event: self.choose_destination())
        fields.Add(choose, 0, wx.ALIGN_CENTER_VERTICAL)
        fields.Add(wx.StaticText(self, label='Format'), 0, wx.ALIGN_CENTER_VERTICAL)
        self.format = wx.Choice(self, choices=['M4B', 'M4A', 'MP3'], name='Output format')
        self.format.SetStringSelection(frame.settings['conversion']['format'].upper())
        self.format.SetToolTip('Choose the file type for the converted audio.')
        self.format.Bind(wx.EVT_CHOICE, self._format_changed)
        fields.Add(self.format, 0, wx.ALIGN_LEFT)
        options = wx.Button(self, label='Conversion &Options…')
        options.SetToolTip('Set audio quality, chapter layout, and metadata options.')
        options.Bind(wx.EVT_BUTTON, lambda _event: self.conversion_options())
        fields.Add(options, 0, wx.ALIGN_CENTER_VERTICAL)
        activation_label = wx.StaticText(self, label='Activation bytes (optional)')
        self.activation = wx.TextCtrl(self, style=wx.TE_PASSWORD, name='Activation bytes (optional)')
        self.activation.SetToolTip('Enter eight hexadecimal activation bytes for an Audible AAX file when required.')
        self.activation.Bind(wx.EVT_TEXT, self.refresh_actions)
        self.activation_row = (
            fields.Add(activation_label, 0, wx.ALIGN_CENTER_VERTICAL),
            fields.Add(self.activation, 0, wx.ALIGN_LEFT),
            fields.AddSpacer(1),
        )
        layout.Add(fields, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(12))
        self.input_warning = wx.StaticText(self)
        layout.Add(self.input_warning, 0, wx.EXPAND | wx.LEFT | wx.RIGHT, self.FromDIP(12))
        actions = wx.BoxSizer(wx.HORIZONTAL)
        actions.AddStretchSpacer()
        self.convert_button = _button(self, actions, '&Convert Selected', self.convert_selection)
        self.convert_button.SetMinSize(self.convert_button.GetBestSize())
        self.convert_button.SetToolTip('Add the selected audio files to the conversion queue.')
        _button(self, actions, 'Help', lambda: frame.show_help('conversion'))
        layout.Add(actions, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        self.SetSizer(layout)
        self.refresh_actions()

    def activate(self):
        self.sync_settings()
        (self.list if self.files else self.files_button).SetFocus()

    def sync_settings(self):
        self.destination.ChangeValue(str(self.frame.settings['archive_root']))
        self.format.SetStringSelection(self.frame.settings['conversion']['format'].upper())
        self.refresh_actions()

    def _save_preference(self, data, key, value):
        try:
            with save_settings_changes(self.frame):
                data[key] = value
        except (OSError, ValueError) as error:
            _tell(self, error, 'Conversion Settings Could Not Be Saved')
            return False
        finally:
            self.sync_settings()
        return True

    def _format_changed(self, _event):
        self._save_preference(self.frame.settings['conversion'], 'format', self.format.GetStringSelection().lower())

    def add_files(self):
        with wx.FileDialog(self, 'Add Audio Files', wildcard=AUDIO_WILDCARD, style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST | wx.FD_MULTIPLE) as dialog:
            if dialog.ShowModal() == wx.ID_OK:
                self.add_paths(dialog.GetPaths())

    def add_folder(self):
        with wx.DirDialog(self, 'Add Audio Folder', style=wx.DD_DIR_MUST_EXIST) as dialog:
            if dialog.ShowModal() == wx.ID_OK:
                self.add_paths([dialog.GetPath()])

    def add_paths(self, paths):
        if self.work.running:
            return
        paths = list(map(Path, paths))
        self.status.SetLabel('Reading audio files…')

        def scan(cancel, _progress):
            files = []
            failures = []
            for path in paths:
                try:
                    files.extend(self.frame.tools.scan(path, cancel=cancel))
                except MediaCancelled:
                    raise
                except (OSError, ValueError) as error:
                    failures.append((path, error))
            return files, failures

        def complete(result):
            files, failures = result
            selected = {self.files[index].path for index in _select(self.list)}
            known = {item.path for item in self.files}
            for item in files:
                if item.path in known:
                    continue
                known.add(item.path)
                self.files.append(item)
            self._render_files(selected)
            self.status.SetLabel(self._file_count() if files else 'No supported audio files were found.')
            if self.files:
                self.list.SetFocus()
            if failures:
                path, error = failures[0]
                title = f'Could Not Open {path.name}' if len(failures) == 1 else 'Could Not Open Some Audio Files'
                _tell(self, error, title)

        def failed(error):
            self.status.SetLabel(self._file_count())
            self.refresh_actions()
            if not isinstance(error, MediaCancelled):
                _tell(self, error, 'Add Audio Files')

        self.work.run(scan, complete, failed)
        self.refresh_actions()

    def _sort(self, event):
        column = event.GetColumn()
        self.sort_descending = not self.sort_descending if self.sort_column == column else False
        self.sort_column = column
        self._render_files({self.files[index].path for index in _select(self.list)})

    def _render_files(self, selected):
        keys = (
            lambda item: natural_key(item.title),
            lambda item: natural_key(item.author or ''),
            lambda item: item.format,
            lambda item: item.duration_seconds or 0,
            lambda item: natural_key(str(item.path)),
        )
        self.files.sort(key=keys[self.sort_column], reverse=self.sort_descending)
        self.rebuilding = True
        self.list.Freeze()
        try:
            self.list.DeleteAllItems()
            for row, item in enumerate(self.files):
                self.list.InsertItem(row, item.title)
                self.list.SetItem(row, 1, item.author or '')
                self.list.SetItem(row, 2, item.format.upper())
                self.list.SetItem(row, 3, _duration(round(item.duration_seconds * 1000)) if item.duration_seconds else 'Unknown')
                self.list.SetItem(row, 4, str(item.path))
                if item.path in selected:
                    self.list.Select(row)
        finally:
            self.list.Thaw()
            self.rebuilding = False
        self.refresh_actions()

    def remove(self):
        for index in reversed(_select(self.list)):
            self.list.DeleteItem(index)
            del self.files[index]
        self.status.SetLabel(self._file_count())
        self.refresh_actions()

    def clear(self):
        self.files.clear()
        self.list.DeleteAllItems()
        self.status.SetLabel('Add files or a folder to convert audio.')
        self.refresh_actions()

    def _file_count(self):
        count = len(self.files)
        return '1 audio file' if count == 1 else f'{count} audio files'

    def choose_destination(self):
        with wx.DirDialog(self, 'Choose Conversion Destination', defaultPath=self.destination.GetValue()) as dialog:
            if dialog.ShowModal() == wx.ID_OK and self._save_preference(
                self.frame.settings, 'archive_root', dialog.GetPath()
            ):
                self.frame.library.render()

    def conversion_options(self):
        self.frame.show_settings('Conversion')
        self.sync_settings()

    def _activation(self, files):
        if not any(item.format == 'aax' for item in files):
            return ''
        value = self.activation.GetValue().strip()
        if value and not valid_activation_bytes(value):
            return None
        return value

    def convert_selection(self):
        files = self.selected_files() or self.files
        if not self.convert_button.IsEnabled() or not files:
            return
        options = self.frame.settings['conversion'].copy()
        if activation := self._activation(files):
            options['activation_bytes'] = activation
        self.frame.enqueue_conversion([item.path for item in files], options)

    def edit(self):
        items = self.selected_files()
        if not self.edit_button.IsEnabled() or not items:
            return
        self.frame.media_views.edit(items, activation_bytes=self._activation(items))

    def selected_files(self):
        return [self.files[index] for index in _select(self.list) if index < len(self.files)]

    def refresh_actions(self, _event=None):
        if self.rebuilding:
            return
        selected = self.selected_files()
        ready = not self.work.running
        queue = getattr(self.frame, 'queue', None)
        idle = queue is None or not queue.active
        files = selected or self.files
        valid_activation = self._activation(files) is not None
        valid_encoding = not ConversionOptions.read(self.frame.settings['conversion']).has_incompatible_bitrate
        valid_archive = ArchiveLayout.from_settings(self.frame.settings, self.frame.data_dir).is_valid
        show_activation = any(item.format == 'aax' for item in self.files)
        for component in self.activation_row:
            component.Show(show_activation)
        warning = ''
        if not valid_activation:
            warning = 'Enter eight hexadecimal activation characters or leave the field blank.'
        elif not valid_encoding:
            warning = 'Choose a lower bitrate or a higher sample rate in Conversion Options.'
        elif not valid_archive:
            warning = 'Check the archive folder and filename templates in Settings > Files.'
        self.input_warning.SetLabel(warning)
        self.input_warning.Show(bool(warning))
        self.files_button.Enable(ready)
        self.folder_button.Enable(ready)
        self.remove_button.Enable(bool(selected))
        self.edit_button.Enable(bool(selected) and ready and idle and valid_activation)
        self.clear_button.Enable(bool(self.files) and ready)
        self.convert_button.Enable(bool(files) and ready and idle and valid_activation and valid_encoding and valid_archive)
        self.convert_button.SetLabel('&Convert Selected' if selected else '&Convert All')
        self.Layout()

    def _key(self, event):
        if event.GetKeyCode() in (wx.WXK_DELETE, wx.WXK_BACK):
            self.remove()
        elif event.ControlDown() and event.GetKeyCode() == ord('A'):
            self.select_all()
        else:
            event.Skip()

    def select_all(self):
        self.rebuilding = True
        try:
            for index in range(len(self.files)):
                self.list.Select(index)
        finally:
            self.rebuilding = False
        self.refresh_actions()

    def _context(self, _event):
        selected = self.selected_files()
        if not selected:
            return
        menu = wx.Menu()
        try:
            actions = [('Convert', self.convert_selection, self.convert_button.IsEnabled()),
                       ('Edit Book…', self.edit, self.edit_button.IsEnabled()),
                       ('Show in File Explorer', self.reveal_selection, True),
                       ('Open Audio in Default Player', self.open_selection,
                        any(item.format in PLAYER_FORMATS for item in selected)),
                       ('Export CUE Sheet…', self.export_cue, self.can_export_cue()),
                       ('Copy Path', self.copy_paths, True),
                       ('Remove from List', self.remove, True),
                       ('Clear List', self.clear, self.clear_button.IsEnabled())]
            for label, callback, enabled in actions:
                item = menu.Append(wx.ID_ANY, label)
                item.Enable(enabled)
                menu.Bind(wx.EVT_MENU, lambda _event, callback=callback: self.frame.guard(callback), item)
            self.list.PopupMenu(menu)
        finally:
            menu.Destroy()

    def reveal_selection(self):
        folders = set()
        for item in self.selected_files():
            if item.path.parent not in folders:
                self.frame.show_file(item.path)
                folders.add(item.path.parent)

    def open_selection(self):
        for item in self.selected_files():
            if item.format in PLAYER_FORMATS:
                self.frame.open_file(item.path)

    def can_export_cue(self):
        selected = self.selected_files()
        return (len(selected) == 1 and supports_cue(selected[0].path) and not self.work.running
                and not self.frame.media_views.cue_work.running)

    def export_cue(self):
        if self.can_export_cue():
            self.frame.media_views.export_cue(self.selected_files()[0].path)

    def copy_paths(self):
        text = '\n'.join(str(item.path) for item in self.selected_files())
        if text and wx.TheClipboard.Open():
            try:
                wx.TheClipboard.SetData(wx.TextDataObject(text))
            finally:
                wx.TheClipboard.Close()


class BookEditor(wx.Dialog):
    def __init__(self, frame, paths, *, book=None, local_metadata=None, activation_bytes='', destination=None,
                 audible_original=False):
        super().__init__(frame, title='Edit Book', style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.frame, self.paths, self.book = frame, list(paths), book
        self.activation = activation_bytes
        self.destination = destination
        self.audible_original = audible_original
        self.chapters = None
        self.chapter_repair = None
        self.chapter_details = None
        self.original_layout = None
        self.separating_announcements = False
        self.repairing = False
        self.layout = []
        self.inputs = []
        self.revisions = {}
        self.data = None
        self.loading = True
        self.work = _Work(self)
        self.temp = tempfile.TemporaryDirectory(prefix='DownAudible Preview-', ignore_cleanup_errors=True)
        self.player = None
        self.preview_timer = None
        self.download_job = None
        self.download_timer = wx.Timer(self)
        self.Bind(wx.EVT_TIMER, self._download_update, self.download_timer)
        self.account = frame.library.active_account_id
        self.client = frame.library.client
        self.api = api_options(frame.settings)
        self.metadata = book or local_metadata or {}
        self.Bind(wx.EVT_CLOSE, self._close)

        layout = wx.BoxSizer(wx.VERTICAL)
        title = str(self.metadata.get('title') or (self.paths[0].stem if self.paths else 'Audiobook'))
        heading = wx.StaticText(self, style=wx.ST_ELLIPSIZE_END)
        heading.SetLabelText(title)
        heading.SetFont(heading.GetFont().Bold())
        layout.Add(heading, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        self.editor_controls = editor = wx.BoxSizer(wx.VERTICAL)
        grid = wx.FlexGridSizer(cols=2, vgap=self.FromDIP(6), hgap=self.FromDIP(8))
        grid.AddGrowableCol(1)
        self.fields = {}
        for key, label in [('title', 'Title'), ('authors', 'Authors'), ('narrators', 'Narrators'), ('series', 'Series')]:
            value = self.metadata.get(key) or ''
            if isinstance(value, list):
                value = ', '.join(value)
            if key == 'title' and not value:
                value = title
            grid.Add(wx.StaticText(self, label=label), 0, wx.ALIGN_CENTER_VERTICAL)
            self.fields[key] = wx.TextCtrl(self, value=str(value), name=label)
            grid.Add(self.fields[key], 1, wx.EXPAND)
        editor.Add(grid, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(12))

        repair_options = wx.BoxSizer(wx.HORIZONTAL)
        self.repair_button = _button(self, repair_options, 'Repair Chapters…', self._chapter_menu)
        self.repair_button.SetToolTip('Rebuild chapter markers from Audible metadata for this recording.')
        self.separate_intro = wx.CheckBox(self, label='Separate Audible Intro and Outro')
        self.separate_intro.Bind(wx.EVT_CHECKBOX, lambda event: self._repair_chapters(
            detail=self.chapter_details, separate=event.IsChecked()
        ))
        repair_options.Add(self.separate_intro, 0, wx.ALIGN_CENTER_VERTICAL | wx.LEFT, self.FromDIP(8))
        self.separate_intro.Hide()
        editor.Add(repair_options, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(12))

        self.sections = report_list(self, 'Audio sections to keep', (
            ('Section', 230), ('Part', 70), ('Duration', 95),
        ), fill=0, style=wx.LC_SINGLE_SEL)
        self.sections.EnableCheckBoxes()
        self.sections.Bind(wx.EVT_LIST_ITEM_SELECTED, self._update)
        self.sections.Bind(wx.EVT_LIST_ITEM_DESELECTED, self._update)
        self.sections.Bind(wx.EVT_LIST_ITEM_CHECKED, self._update)
        self.sections.Bind(wx.EVT_LIST_ITEM_UNCHECKED, self._update)
        self.sections.Bind(wx.EVT_LIST_KEY_DOWN, self._key)
        self.sections.Bind(wx.EVT_CONTEXT_MENU, self._part_menu)
        self.sections.SetToolTip('Keep or omit audio sections. Select a row to preview its start or end.')
        editor.Add(self.sections, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, self.FromDIP(12))

        self.status = wx.StaticText(self, label='Reading audio and chapters…')
        editor.Add(self.status, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        actions = wx.BoxSizer(wx.HORIZONTAL)
        self.start_button = _button(self, actions, 'Preview &Start', lambda: self.preview(False))
        self.end_button = _button(self, actions, 'Preview &End', lambda: self.preview(True))
        self.stop_button = _button(self, actions, 'Stop Preview', self.stop_preview)
        self.read_again = _button(self, actions, 'Try Again', self._read_sources)
        actions.AddStretchSpacer()
        self.convert_button = _button(self, actions, 'Convert to &M4B', self.on_convert)
        self.start_button.SetToolTip('Listen to the beginning of the selected audio section.')
        self.end_button.SetToolTip('Listen to the end of the selected audio section.')
        self.convert_button.SetToolTip('Save the checked audio sections in a new M4B file.')
        cancel = wx.Button(self, wx.ID_CANCEL)
        cancel.Bind(wx.EVT_BUTTON, self._close)
        actions.Add(cancel)
        editor.Add(actions, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        layout.Add(editor, 1, wx.EXPAND)
        self.download_controls = self._build_download_controls()
        layout.Add(self.download_controls, 1, wx.EXPAND | wx.ALL, self.FromDIP(12))
        layout.Show(editor, bool(self.paths))
        layout.Show(self.download_controls, not self.paths)
        self.SetSizer(layout)
        self.SetSize(self.FromDIP(wx.Size(750, 550)))
        self.SetMinSize(self.FromDIP(wx.Size(600, 450)))
        self.CenterOnParent()
        if self.paths:
            self._read_sources()
        else:
            self.download_progress.Hide()
            self.download_button.SetFocus()
        self._update()

    def _build_download_controls(self):
        layout = wx.BoxSizer(wx.VERTICAL)
        self.download_detail = wx.StaticText(self, label='Download the original audio to preview and edit this book.')
        layout.Add(self.download_detail, 0, wx.EXPAND | wx.BOTTOM, self.FromDIP(8))
        self.download_progress = wx.Gauge(self, range=100, name='Original audio download progress')
        layout.Add(self.download_progress, 0, wx.EXPAND | wx.BOTTOM, self.FromDIP(8))
        layout.AddStretchSpacer()
        buttons = wx.BoxSizer(wx.HORIZONTAL)
        buttons.AddStretchSpacer()
        self.download_button = _button(self, buttons, '&Download Original', self._start_download)
        self.download_button.SetToolTip('Save the audiobook’s original audio and load it in this editor.')
        _button(self, buttons, 'Close', lambda: self._close(None))
        layout.Add(buttons, 0, wx.EXPAND)
        return layout

    def _start_download(self):
        if self.frame.queue.pending:
            self._download_message('Wait for the current transfers to finish, then try again.')
            return
        options = {
            'account_id': self.account,
            'downloadAudio': True, 'keepOriginal': True, 'convert': False,
            'downloadPDF': False, 'downloadCover': False, 'downloadChapters': False,
            'downloadAnnotations': False, 'open_after_saving': 'off',
        }
        if not self.frame.enqueue_books([self.book], options=options, reveal=False):
            return
        current = self.frame.queue.snapshot()['current']
        self.download_job = current['jobs'][0]['id']
        self.download_button.Disable()
        self.download_progress.Show()
        self.download_timer.Start(180)
        self._download_update()

    def _download_message(self, message):
        self.download_detail.SetLabelText(message)
        self.download_detail.Wrap(max(self.FromDIP(160), self.GetClientSize().width - self.FromDIP(24)))
        self.Layout()

    def _download_update(self, _event=None):
        current = self.frame.queue.snapshot()['current']
        job = next((item for item in current['jobs'] if item['id'] == self.download_job), None) if current else None
        if job and job['status'] in {'Waiting', 'Running'}:
            fraction = job.get('progress')
            if fraction is None:
                self.download_progress.Pulse()
            else:
                self.download_progress.SetValue(max(0, min(100, round(fraction * 100))))
            self._download_message(job.get('detail') or 'Preparing download…')
            return
        self.download_timer.Stop()
        failure = job.get('detail') if job else None
        if job and job['status'] in {'Completed', 'Warning'}:
            files = map(Path, job.get('files', ()))
            self.paths = [path for path in files if path.suffix.casefold().lstrip('.') in AUDIO_FORMATS and path.is_file()]
            if self.paths:
                self.audible_original = True
                self.GetSizer().Show(self.download_controls, False)
                self.GetSizer().Show(self.editor_controls, True)
                self.Layout()
                self._read_sources()
                return
            failure = 'The original audio could not be found in the archive.'
        self.download_progress.Hide()
        self.download_button.SetLabel('&Retry Download')
        self.download_button.Enable()
        self.download_button.SetFocus()
        self._download_message(failure or 'The original audio could not be loaded.')

    def _read_sources(self):
        self.read_again.Hide()
        self.loading = True
        self.status.SetLabel('Reading audio and chapters…')
        self.Layout()
        self.work.run(self._load, self._ready, self._read_failed)
        self._update()

    def _read_failed(self, error):
        self._failed(error)
        self.read_again.Show()
        self.Layout()
        self.read_again.SetFocus()

    def _load(self, cancel, _progress):
        from .audible import AudibleError

        paths, account = self.paths, self.account
        revisions = {str(path): source_revision(path) for path in paths}
        activation = self.activation
        if account and not activation and any(path.suffix.lower() == '.aax' for path in paths):
            activation = self._account_activation(cancel)
        inputs = []
        for path in paths:
            credentials = {}
            if path.suffix.lower() == '.aaxc':
                try:
                    credentials = self.frame.runner.book_voucher(path, self.metadata, account, cancel=cancel, options=self.api)
                except AudibleError:
                    pass  # MediaTools can still read an adjacent voucher.
            inputs.append(MediaInput(path, activation, credentials.get('contentKey', ''),
                                     credentials.get('contentIV', ''), expected_revision=revisions[str(path)]))
        chapters = self._audible_chapters(paths, cancel)
        layout = self.frame.tools.sections(inputs, chapters=chapters, cancel=cancel,
                                           refresh_activation=(lambda: self._account_activation(cancel, refresh=True))
                                           if account and not self.activation else None)
        return layout, chapters, inputs, revisions

    def _audible_chapters(self, paths, cancel):
        from .audible import AudibleError

        if not (self.audible_original and len(paths) == 1 and self.account and self.book):
            return None
        try:
            files = self.frame.tools.scan(paths[0], cancel=cancel)
            asin = self.book.get('asin')
            if asin and files and files[0].asin == asin:
                return self.client.run('chapters', account_id=self.account, cancel=cancel, options=self.api, asin=asin)
        except MediaCancelled:
            raise
        except (AudibleError, OSError, ValueError):
            pass
        return None

    def _account_activation(self, cancel, *, refresh=False):
        session = self.client.session(self.account)
        result = self.client.run('activation', session=session, cancel=cancel, options=self.api, refreshActivation=refresh)
        if result.get('session') and not self.frame.demo:
            self.client.update_session(self.account, session, result['session'])
        return result.get('activationBytes', '')

    def _ready(self, result):
        self.layout, self.chapters, self.inputs, self.revisions = result
        self._render_sections('Clear the checkbox beside any section you want to omit.')

    def _render_sections(self, status):
        self.loading = True
        self.sections.DeleteAllItems()
        for section in self.layout:
            index = self.sections.InsertItem(self.sections.GetItemCount(), section.title)
            self.sections.SetItem(index, 1, str(section.source_index + 1))
            self.sections.SetItem(index, 2, _duration(section.end_ms - section.start_ms))
            self.sections.CheckItem(index)
        self.loading = False
        if self.layout:
            self.sections.Select(0)
            self.sections.SetFocus()
        self.status.SetLabel(status)
        self.Layout()
        self._update()

    def _chapter_menu(self):
        menu = wx.Menu()
        try:
            actions = []
            if self.metadata.get('asin') and self.account and self.frame.library.is_signed_in(self.account):
                actions.append(('Get Chapters from Audible', self._repair_chapters))
            actions.append(('Choose Chapter JSON…', self._choose_chapter_file))
            if self.original_layout is not None:
                actions.append(('Use Existing Chapters', self._restore_chapters))
            for label, action in actions:
                item = menu.Append(wx.ID_ANY, label)
                menu.Bind(wx.EVT_MENU, lambda _event, action=action: action(), item)
            position = self.repair_button.GetPosition()
            self.PopupMenu(menu, wx.Point(position.x, position.y + self.repair_button.GetSize().height))
        finally:
            menu.Destroy()

    def _choose_chapter_file(self):
        with wx.FileDialog(self, 'Choose Chapter JSON', wildcard='JSON files (*.json)|*.json',
                           style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST) as dialog:
            if dialog.ShowModal() == wx.ID_OK:
                self._repair_chapters(file=dialog.GetPath())

    def _repair_chapters(self, *, file=None, detail=None, separate=False):
        if self.work.running or not self.layout:
            return
        self.stop_preview()
        self.repairing = True
        self.status.SetLabel('Checking chapter data…')
        asin = self.metadata.get('asin')

        def prepare(cancel, _progress):
            data = detail or self.client.run('chapterRepair', account_id=self.account, cancel=cancel,
                                             file=file, asin=asin, options=self.api)
            repair = {key: data[key] for key in ('asin', 'runtimeMilliseconds') if key in data}
            repair['chapters'] = data['separatedChapters'] if separate else data['chapters']
            refresh = ((lambda: self._account_activation(cancel, refresh=True))
                       if self.account and not self.activation else None)
            layout = self.frame.tools.sections(self.inputs, chapter_repair=repair, cancel=cancel, refresh_activation=refresh)
            return data, repair, layout

        def ready(result):
            self.repairing = False
            if self.original_layout is None:
                self.original_layout = self.layout
            self.chapter_details, self.chapter_repair, self.layout = result
            self.separating_announcements = separate
            self.separate_intro.Show(bool(self.chapter_details.get('separatedChapters')))
            self.separate_intro.SetValue(separate)
            self._render_sections('Rebuilt Chapters · Clear the checkbox beside any section you want to omit.')

        def failed(error):
            self.repairing = False
            self.separate_intro.SetValue(self.separating_announcements)
            self._failed(error)
            self.repair_button.SetFocus()

        self.work.run(prepare, ready, failed)
        self._update()

    def _restore_chapters(self):
        if self.original_layout is None or self.work.running:
            return
        self.stop_preview()
        self.layout = self.original_layout
        self.original_layout = self.chapter_details = self.chapter_repair = None
        self.separating_announcements = False
        self.separate_intro.SetValue(False)
        self.separate_intro.Hide()
        self._render_sections('Clear the checkbox beside any section you want to omit.')

    def _failed(self, error):
        self.loading = False
        self.status.SetLabel('Preview stopped.' if isinstance(error, MediaCancelled) else str(error))
        self._update()

    def _key(self, event):
        if event.GetKeyCode() == wx.WXK_SPACE and (selection := _select(self.sections)):
            index = selection[0]
            self.sections.CheckItem(index, not self.sections.IsItemChecked(index))
            self._update()
        else:
            event.Skip()

    def _update(self, _event=None):
        if self.loading and self.layout:
            return
        can_preview = not self.work.running and bool(_select(self.sections))
        self.start_button.Enable(can_preview)
        self.end_button.Enable(can_preview)
        self.stop_button.Enable(self.work.running and bool(self.layout) and not self.repairing or self.player is not None)
        self.repair_button.Enable(not self.work.running and bool(self.layout))
        self.separate_intro.Enable(not self.work.running and self.chapter_details is not None)
        self.sections.Enable(not self.repairing)
        count = self.sections.GetItemCount()
        self.convert_button.Enable(not self.work.running and any(self.sections.IsItemChecked(index) for index in range(count)))

    def _part_menu(self, event):
        selected = _select(self.sections)
        if len(self.paths) < 2 or not selected:
            event.Skip()
            return
        part = self.layout[selected[0]].source_index
        menu = wx.Menu()
        try:
            actions = [('Keep This Part', lambda: self._keep_part(part, True)),
                       ('Omit This Part', lambda: self._keep_part(part, False)),
                       ('Preview Start of Part', lambda: self.preview(False, part=True)),
                       ('Preview End of Part', lambda: self.preview(True, part=True))]
            for label, callback in actions:
                item = menu.Append(wx.ID_ANY, label)
                menu.Bind(wx.EVT_MENU, lambda _event, callback=callback: callback(), item)
            self.sections.PopupMenu(menu)
        finally:
            menu.Destroy()

    def _keep_part(self, part, keep):
        self.loading = True
        try:
            for index, section in enumerate(self.layout):
                if section.source_index == part:
                    self.sections.CheckItem(index, keep)
        finally:
            self.loading = False
        self._update()

    def preview(self, end, *, part=False):
        if not (selected := _select(self.sections)) or self.work.running:
            return
        self.stop_preview()
        self.status.SetLabel('Preparing preview…')
        target = Path(self.temp.name) / 'preview.wav'
        target.unlink(missing_ok=True)
        section = self.layout[selected[0]]
        if part:
            group = [item for item in self.layout if item.source_index == section.source_index]
            section = replace(section, start_ms=group[0].start_ms, end_ms=group[-1].end_ms)

        def prepare(cancel, _progress):
            refresh = (lambda: self._account_activation(cancel, refresh=True)) if self.account and not self.activation else None
            return self.frame.tools.preview(self.inputs, section, target, end=end, cancel=cancel, refresh_activation=refresh)

        def play(path):
            try:
                if os.name == 'nt':
                    import winsound

                    winsound.PlaySound(str(path), winsound.SND_ASYNC | winsound.SND_FILENAME | winsound.SND_NODEFAULT)
                    self.player = True
                else:
                    self.player = subprocess.Popen(['afplay', str(path)])
            except (OSError, RuntimeError) as error:
                self._failed(error)
                return
            self.status.SetLabel('Playing preview.')
            self.preview_timer = wx.CallLater(min(10000, section.end_ms - section.start_ms) + 200, self._preview_finished)
            self._update()

        self.work.run(prepare, play, self._failed)
        self._update()

    def stop_preview(self):
        if self.work.running and self.layout:
            self.work.cancel.set()
        if self.preview_timer is not None:
            self.preview_timer.Stop()
            self.preview_timer = None
        if self.player is None:
            return
        if os.name == 'nt':
            import winsound

            winsound.PlaySound(None, 0)
        elif self.player.poll() is None:
            self.player.terminate()
            self.player.wait()
        self.player = None
        self.status.SetLabel('Preview stopped.')
        self._update()

    def _preview_finished(self):
        self.preview_timer = None
        self.player = None
        self.status.SetLabel('Preview finished.')
        self._update()

    def on_convert(self):
        excluded = [section.id for index, section in enumerate(self.layout) if not self.sections.IsItemChecked(index)]
        if len(excluded) == len(self.layout):
            return
        metadata = {**self.metadata}
        for key, field in self.fields.items():
            value = field.GetValue().strip()
            metadata[key] = [part.strip() for part in value.split(',') if part.strip()] if key in {'authors', 'narrators'} else value
        self.data = {
            'sources': [str(path) for path in self.paths], 'book': self.book, 'metadata': metadata,
            'chapters': self.chapters, 'excluded_sections': excluded,
            'expected_sections': [asdict(section) for section in self.layout],
            'revisions': {path: list(revision[2:]) for path, revision in self.revisions.items()},
            'source_revisions': self.revisions,
            'options': {'format': 'm4b', 'chapter_mode': 'single'},
        }
        if self.chapter_repair is not None:
            self.data['chapter_repair'] = self.chapter_repair
        if self.activation:
            self.data['activation_bytes'] = self.activation
        if self.destination:
            self.data['destination'] = str(self.destination)
        if not self.frame.guard(self.frame.enqueue_edit, self.paths[0], self.data):
            return
        self.stop_preview()
        self.EndModal(wx.ID_OK)

    def _close(self, _event):
        self.download_timer.Stop()
        self.stop_preview()
        self.work.cancel.set()
        self.EndModal(wx.ID_CANCEL)

    def Destroy(self):
        self.download_timer.Stop()
        self.stop_preview()
        self.work.cancel.set()
        self.temp.cleanup()
        return super().Destroy()


class ArchiveVerificationDialog(wx.Dialog):
    def __init__(self, frame, books, get_matches, *, on_repair, has_partial=None):
        super().__init__(frame, title='Verify and Repair Archive', style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.frame, self.books, self.issues, self.on_repair = frame, books, [], on_repair
        self.work = _Work(self)
        self.Bind(wx.EVT_CLOSE, self._close)
        layout = wx.BoxSizer(wx.VERTICAL)
        self.status = wx.StaticText(self, label='Finding audio in the archive…')
        layout.Add(self.status, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        self.gauge = wx.Gauge(self, range=100, name='Archive verification progress')
        layout.Add(self.gauge, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(12))
        self.report = report_list(self, 'Archive verification report', (
            ('Title', 240), ('Problem', 140), ('Repair', 100), ('Files', 170),
        ), fill=3)
        self.report.EnableCheckBoxes()
        self.report.Bind(wx.EVT_LIST_ITEM_CHECKED, self._checked)
        self.report.Bind(wx.EVT_LIST_ITEM_UNCHECKED, self._checked)
        self.report.Bind(wx.EVT_LIST_KEY_DOWN, self._key)
        layout.Add(self.report, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, self.FromDIP(12))
        actions = wx.BoxSizer(wx.HORIZONTAL)
        self.select_button = _button(self, actions, 'Select &All Repairable', self.select_all)
        self.repair_button = _button(self, actions, '&Repair Selected', self.repair)
        self.select_button.SetToolTip('Check every listed audiobook that Audible still offers for download.')
        self.repair_button.SetToolTip('Queue replacement audio for the checked audiobooks.')
        actions.AddStretchSpacer()
        self.close_button = _button(self, actions, 'Cancel', self._close)
        self.SetEscapeId(self.close_button.GetId())
        layout.Add(actions, 0, wx.EXPAND | wx.ALL, self.FromDIP(12))
        self.SetSizer(layout)
        self.SetSize(self.FromDIP(wx.Size(800, 470)))
        self.SetMinSize(self.FromDIP(wx.Size(570, 340)))
        self.CenterOnParent()
        self._checked()

        def check(cancel, progress):
            result = get_matches(cancel)
            if isinstance(result, tuple):
                matches, sizes = result
            else:
                matches, sizes = result, None
            return verify_archive(books, matches, frame.tools, sizes=sizes, has_partial=has_partial,
                                  cancel=cancel, progress=progress)

        self.work.run(check, self._complete, self._failed, self._progress)

    def _progress(self, fraction):
        self.status.SetLabel('Checking audio…')
        self.gauge.SetValue(round(100 * fraction))

    def _complete(self, issues):
        self.issues = issues
        for issue in issues:
            index = self.report.InsertItem(self.report.GetItemCount(), issue.book.get('title', '') or 'Untitled')
            self.report.SetItem(index, 1, REPAIR_LABELS[issue.kind])
            self.report.SetItem(index, 2, 'Available' if issue.can_repair else 'Unavailable')
            self.report.SetItem(index, 3, ', '.join(str(path) for path in issue.files))
        checked = len(self.books)
        self.status.SetLabel(f'Checked {checked} titles. {len(issues)} need attention.' if issues
                             else f'Checked {checked} titles. No archive problems found.')
        self.gauge.SetValue(100)
        self.close_button.SetLabel('Close')
        self._checked()
        (self.report if issues else self.close_button).SetFocus()

    def _failed(self, error):
        self.status.SetLabel('Verification cancelled.' if isinstance(error, MediaCancelled) else str(error))
        self.close_button.SetLabel('Close')

    def _checked(self, event=None):
        if event:
            index = event.GetIndex()
            if 0 <= index < len(self.issues) and not self.issues[index].can_repair and self.report.IsItemChecked(index):
                self.report.CheckItem(index, False)
        self.select_button.Enable(any(issue.can_repair for issue in self.issues))
        self.repair_button.Enable(any(issue.can_repair and self.report.IsItemChecked(index)
                                      for index, issue in enumerate(self.issues)))

    def select_all(self):
        for index, issue in enumerate(self.issues):
            if issue.can_repair:
                self.report.CheckItem(index)
        self._checked()

    def _key(self, event):
        if event.GetKeyCode() != wx.WXK_SPACE:
            event.Skip()
            return
        rows = [row for row in _select(self.report) if self.issues[row].can_repair]
        check = any(not self.report.IsItemChecked(row) for row in rows)
        for row in rows:
            self.report.CheckItem(row, check)
        self._checked()

    def repair(self):
        selected = [issue.book for index, issue in enumerate(self.issues)
                    if issue.can_repair and self.report.IsItemChecked(index)]
        if selected and self.on_repair(selected) is not False:
            self.EndModal(wx.ID_OK)

    def _close(self, _event=None):
        self.work.cancel.set()
        self.EndModal(wx.ID_CANCEL)


class MediaViews:
    def __init__(self, frame):
        self.frame = frame
        self.converter = None
        self.cue_work = _Work(frame)

    def panel(self, parent):
        self.converter = ConverterPanel(parent, self.frame)
        return self.converter

    def convert(self):
        if hasattr(self.frame, 'show_converter'):
            self.frame.show_converter()
        if self.converter:
            self.converter.activate()

    def export_cue(self, path):
        def saved(target):
            self.frame.set_status(f'Saved {target.name} beside the audio file.')
            self.frame.guard(self.frame.show_file, target)

        def failed(error):
            if not isinstance(error, MediaCancelled):
                _tell(self.frame, error, 'Could Not Export CUE Sheet')

        self.cue_work.run(lambda cancel, _progress: write_cue_sheet(path, self.frame.tools, cancel=cancel), saved, failed)

    def edit(self, selection=None, *, activation_bytes='', destination=None):
        if selection is None:
            if self.converter:
                self.converter.edit()
            return
        if self.frame.queue.active:
            _tell(self.frame, 'Wait for the current transfers to finish, then open the editor again.', 'Edit Book')
            return
        if isinstance(selection, dict):
            book = selection
            paths, audible_original = self._book_paths(book)
            paths = list(dict.fromkeys(map(Path, paths)))
            local_metadata = None
            if not paths and not book.get('isDownloadable'):
                _tell(self.frame, 'Match an existing audio file to this title before editing it.', 'Edit Book')
                return
        else:
            book = None
            audible_original = False
            items = [selection] if isinstance(selection, (str, Path, LocalAudio)) else list(selection)
            paths, local_metadata = _local_book_inputs(items)
        if not paths and book is None:
            return
        with BookEditor(self.frame, paths, book=book, local_metadata=local_metadata,
                        activation_bytes=activation_bytes, destination=destination,
                        audible_original=audible_original) as dialog:
            dialog.ShowModal()

    def _book_paths(self, book):
        matched = self.frame.match_paths(book)
        if matched and all(path.is_file() for path in matched):
            return matched, False
        groups, _ = self.frame.archive_verification_matches([book])
        candidates = []
        for files in groups.get(book['asin'], ()):
            paths = list(map(Path, files))
            if not paths or not all(path.is_file() for path in paths):
                continue
            try:
                date = min(path.stat().st_mtime_ns for path in paths)
            except OSError:
                continue
            original = all(path.suffix.lower() in {'.aax', '.aaxc', '.aa'} for path in paths)
            candidates.append((original, date, paths))
        original, _, paths = max(candidates, key=lambda item: item[:2], default=(False, 0, []))
        return paths, original

    def verify(self, books=None, matches=None, repair=None):
        if self.frame.library.all_accounts and books is None:
            _tell(self.frame, 'Choose one Audible account in Library before verifying its archive.', 'Verify and Repair Archive')
            return
        books = list(self.frame.library.books if books is None else books)
        root = self.frame.settings.get('archive_root')
        if self.frame.queue.active:
            _tell(self.frame, 'Wait for the current transfers to finish, then try again.', 'Verify and Repair Archive')
            return
        if not books:
            _tell(self.frame, 'Open an Audible library with books before verifying the archive.', 'Verify and Repair Archive')
            return
        account = self.frame.settings.get('audible_account')

        try:
            archive_root = Path(root).resolve() if root else None
        except (OSError, RuntimeError):
            _tell(self.frame, 'DownAudible could not open the archive destination. Check Settings > Files.',
                  'Verify and Repair Archive')
            return
        self.frame._load_receipts()
        available = self.frame.archive_verification_matches(books, root=archive_root) if matches is None else matches

        def get_matches(cancel):
            if matches is not None:
                return matches
            if archive_root is None or not archive_root.is_dir() or not os.access(archive_root, os.R_OK):
                raise ArchiveError('DownAudible could not open the archive destination. Check Settings > Files.')
            return available

        def on_repair(selected):
            if (root != self.frame.settings.get('archive_root') or account != self.frame.settings.get('audible_account')):
                _tell(self.frame, 'The account or destination changed. Verify the archive again.', 'Repair Archive')
                return False
            if self.frame.queue.pending:
                _tell(self.frame, 'Wait for the current transfers to finish, then try again.', 'Repair Archive')
                return False
            if repair:
                return repair(selected)
            return bool(self.frame.enqueue_books(selected, options={'downloadAudio': True, 'repair': True}))

        with ArchiveVerificationDialog(self.frame, books, get_matches, on_repair=on_repair,
                                       has_partial=self.frame.has_incomplete_download if matches is None else None) as dialog:
            dialog.ShowModal()

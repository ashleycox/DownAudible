"""DownAudible's Windows desktop entry point."""

import argparse
import logging
import os
import shutil
import subprocess
import sys
import tempfile
from collections import deque
from copy import deepcopy
from pathlib import Path
from threading import Thread
from uuid import uuid4

import wx
import wx.adv

from .archive import ArchiveCopy, match_books, recorded_file
from .audible import AudibleError
from .audiobookshelf import ShelfError, UploadQueue, UploadTarget, stored_token
from .audiobookshelf_views import ShelfUploadsDialog
from .helpbook import build_help
from .jobs import SECRET_SETTINGS, JobRunner, stable_id
from .library import LibraryPanel
from .library_catalog import book_identity, profile_id
from .media import MediaTools
from .media_views import MediaViews
from .notification_sounds import duration_ms
from .queue import RETRYABLE, BatchQueue
from .release import installed_release
from .settings_views import SettingsDialog, SetupDialog, place_dialog
from .state import (
    DEFAULT_DOWNLOAD,
    FEEDBACK_EVENTS,
    app_data,
    load_settings,
    read_json,
    write_json,
)
from .transfer_views import DownloadDialog, TransfersPanel
from .updater import (
    UpdateError,
    check_update,
    download_verified,
    running_windows_architecture,
    schedule_verified_install,
)

LOG = logging.getLogger(__name__)
CHECKED_DOWNLOAD_OUTPUTS = ("downloadAudio", "downloadPDF", "downloadCover", "downloadChapters", "downloadAnnotations")
RELEASE = installed_release()
VERSION = RELEASE.version
ROOT = Path(__file__).resolve().parents[1]
PROJECT = "https://github.com/ashleycox/DownAudible"
DONATION = "https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE"


def default_resources():
    configured = os.environ.get("DOWNAUDIBLE_RESOURCES")
    return Path(configured) if configured else ROOT / "resources"


def media_tools(resources, *, demo=False):
    if sys.platform == "win32":
        return MediaTools(resources / "Media" / "ffmpeg.exe", resources / "Media" / "ffprobe.exe")
    local = Path("/Applications/DownAudible.app/Contents/Resources/MediaSupport")
    return MediaTools(*(local / tool if not demo and (local / tool).is_file() else Path(shutil.which(tool) or tool)
                        for tool in ("ffmpeg", "ffprobe")))


class MainFrame(wx.Frame):
    def __init__(self, data_dir, resource_dir, *, demo=False, test_mode=False):
        super().__init__(None, title="DownAudible", size=(1230, 770), name="DownAudible")
        self.data_dir, self.resource_dir, self.demo = data_dir, resource_dir, demo
        icon = resource_dir / "DownAudible.ico"
        if icon.is_file():
            self.SetIcon(wx.Icon(str(icon), wx.BITMAP_TYPE_ICO))
        elif (resource_dir / "DownAudible.png").is_file():
            app_icon = wx.Icon()
            thumbnail = wx.Image(str(resource_dir / "DownAudible.png"), wx.BITMAP_TYPE_PNG).Scale(64, 64, wx.IMAGE_QUALITY_HIGH)
            app_icon.CopyFromBitmap(wx.Bitmap(thumbnail))
            self.SetIcon(app_icon)
        self.test_mode = test_mode
        self.settings_path = data_dir / "Settings.json"
        self.settings = load_settings(self.settings_path)
        wx.ToolTip.Enable(self.settings["show_help_tags"])
        if demo:
            self.settings["archive_root"] = str(data_dir / "Audiobooks")
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.tools = media_tools(resource_dir, demo=demo)
        self._help_root = None
        self._update_checking = False
        self._staged_update = None
        self._staged_release = None
        self._restart_for_update = False
        self._closed = False
        self._exit_pending = False
        self._exit_without_saving = False
        self._notifications = {}
        self._feedback_sounds = deque()
        self._feedback_timer = None
        self._refresh_pending = False
        self._latest_status = None
        self._receipts = {}
        self._pdf_receipts = {}
        self._index_generation = 0
        self._index_pending = False
        self._index_callbacks = []
        self._load_receipts()

        content = wx.Panel(self)
        self.content_sizer = wx.BoxSizer(wx.HORIZONTAL)
        content.SetSizer(self.content_sizer)
        inset = self.FromDIP(12)
        self.sidebar = wx.ListBox(
            content, choices=["Library", "Convert Files", "Downloads"], name="Workspaces",
            style=wx.LB_SINGLE | wx.BORDER_NONE,
        )
        if wx.Platform == "__WXMSW__":
            self.sidebar.SetLabel("Workspaces")
        self.sidebar.SetBackgroundColour(content.GetBackgroundColour())
        best = self.sidebar.GetBestSize()
        self.sidebar.SetMinSize((max(self.FromDIP(138), best.width), best.height))
        self.sidebar.Bind(wx.EVT_LISTBOX, lambda event: self.show_workspace(event.GetSelection(), focus=False))
        self.content_sizer.Add(self.sidebar, 0, wx.ALL, inset)
        self.sidebar_divider = wx.StaticLine(content, style=wx.LI_VERTICAL)
        self.content_sizer.Add(self.sidebar_divider, 0, wx.EXPAND | wx.TOP | wx.BOTTOM, inset)
        self.workspace = wx.Panel(content)
        self.workspace.layout = wx.BoxSizer(wx.VERTICAL)
        self.workspace.SetSizer(self.workspace.layout)
        self.content_sizer.Add(self.workspace, 1, wx.EXPAND | wx.ALL, inset)
        self.library = LibraryPanel(self.workspace, self)
        self.media_views = MediaViews(self)
        self.converter = self.media_views.panel(self.workspace)
        self.transfers = TransfersPanel(self.workspace, self)
        self.pages = [self.library, self.converter, self.transfers]
        for page in self.pages:
            self.workspace.layout.Add(page, 1, wx.EXPAND)
        self.audiobookshelf = UploadQueue(
            data_dir / "Audiobookshelf Uploads.json",
            changed=lambda status, detail: wx.CallAfter(self.shelf_upload_changed, status, detail),
        )
        self.configure_audiobookshelf()
        self.runner = JobRunner(data_dir, self.library.client, self.tools, demo=demo,
                                completed_download=self.queue_audiobookshelf,
                                widevine_enabled=self.library.widevine_enabled_for)
        self.queue = BatchQueue(data_dir / "Queue.json", self.runner.run, self.queue_changed,
                                lambda batch, events, settings: wx.CallAfter(self.finish_batch, batch, events, settings),
                                has_partial=self.runner.has_partial)
        self.runner.pacer.configure(self.settings.get("daily_download_limit"))
        self.transfers.refresh()
        self.layout = wx.BoxSizer(wx.VERTICAL)
        self.layout.Add(content, 1, wx.EXPAND)
        self.SetSizer(self.layout)

        self.CreateStatusBar()
        self.GetStatusBar().Show(self.settings["show_status"])
        self.sidebar.Show(self.settings["show_sidebar"])
        self.sidebar_divider.Show(self.settings["show_sidebar"])
        self.status = self.GetStatusBar()
        self.set_status("Ready")
        if self.queue.recovery_warning:
            wx.CallAfter(self.error, self.queue.recovery_warning, "Could Not Restore Transfer Queue")
        self._menu_bar()
        self.Bind(wx.EVT_MENU_OPEN, self.refresh_open_menus)
        self.show_workspace(0)
        self.Bind(wx.EVT_CLOSE, self.on_close)
        self.fit_display()
        self.watcher = wx.Timer(self)
        self.Bind(wx.EVT_TIMER, lambda event: self.scan_archive(), self.watcher)
        self.update_timer = wx.Timer(self)
        self.Bind(wx.EVT_TIMER, lambda event: self.check_updates(quiet=True) if self.settings["check_updates"] else None,
                  self.update_timer)
        if not demo:
            self.watcher.Start(15000)
            self.update_timer.Start(6 * 60 * 60 * 1000)
            wx.CallAfter(self.scan_archive)
            wx.CallAfter(self.start_update_checks)

    def fit_display(self):
        work = wx.Display(0).GetClientArea()
        if work.width > 0 and work.height > 0:
            margin = 2 * self.FromDIP(12)
            width = min(self.FromDIP(1230), max(1, work.width - margin))
            height = min(self.FromDIP(770), max(1, work.height - margin))
            self.SetMinSize((min(self.FromDIP(920), width), min(self.FromDIP(530), height)))
            self.SetSize((width, height))
            self.SetPosition((work.x + (work.width - width) // 2, work.y + (work.height - height) // 2))

    def guard(self, callback, *args, **kwargs):
        try:
            return callback(*args, **kwargs)
        except Exception as error:
            self.error(str(error) or type(error).__name__)

    def error(self, message, title="DownAudible"):
        if self.test_mode:
            LOG.error("%s: %s", title, message)
        else:
            wx.MessageBox(message, title, wx.OK | wx.ICON_ERROR, self)

    def set_status(self, value):
        if hasattr(self, "status"):
            self.SetStatusText(value)
        self._latest_status = value

    def save_settings(self):
        write_json(self.settings_path, self.settings)
        if hasattr(self, "library"):
            self.library.configure_background_refresh()
        if hasattr(self, "audiobookshelf"):
            self.configure_audiobookshelf()
        runner = getattr(self, "runner", None)
        if runner is not None and runner.pacer.configure(self.settings.get("daily_download_limit")):
            self.queue.pacing_changed()
        self.sidebar.Show(self.settings["show_sidebar"])
        self.sidebar_divider.Show(self.settings["show_sidebar"])
        self.GetStatusBar().Show(self.settings["show_status"])
        wx.ToolTip.Enable(self.settings["show_help_tags"])
        self.Layout()

    def show_settings(self, page=None):
        was_checking = self.settings["check_updates"]
        with SettingsDialog(self, page) as dialog:
            if dialog.ShowModal() == wx.ID_OK:
                self.converter.sync_settings()
                self.transfers.refresh()
                self.library.render()
                self.scan_archive()
                if self.settings["check_updates"] and not was_checking:
                    self.check_updates(quiet=True)

    def setup(self):
        with SetupDialog(self) as dialog:
            result = dialog.ShowModal()
        if result == wx.ID_HELP:
            self.show_help()
        self.library.update_accounts()
        self.library.render()
        self.converter.sync_settings()

    def configure_audiobookshelf(self):
        settings = self.settings["audiobookshelf"]
        try:
            target = UploadTarget.from_settings(settings)
            token = stored_token(self.library.client, target.server) if target else ""
        except ShelfError as error:
            self.audiobookshelf.configure(None, "")
            wx.CallAfter(self.shelf_upload_changed, "Failed", str(error))
            return
        self.audiobookshelf.configure(target, token, automatic=bool(settings.get("auto_upload")),
                                     include_pdf=bool(settings.get("include_pdf")))

    def queue_audiobookshelf(self, book, receipt):
        try:
            self.audiobookshelf.upload_automatically(book, receipt)
        except (ShelfError, OSError) as error:
            message = str(error) if isinstance(error, ShelfError) else "A saved audio file could not be read for upload."
            wx.CallAfter(self.shelf_upload_changed, "Failed", message)

    def shelf_upload_changed(self, status, detail):
        if status == "Failed" and not self._closed:
            self.set_status(f"Audiobookshelf upload failed. {detail}")

    def show_audiobookshelf(self):
        with ShelfUploadsDialog(self, position=place_dialog) as dialog:
            dialog.ShowModal()

    def _menu_bar(self):
        menubar = wx.MenuBar()
        self._menu_populators = {}

        def item(menu, label, action, *, checked=None):
            entry = menu.Append(wx.ID_ANY, label) if checked is None else menu.AppendCheckItem(wx.ID_ANY, label)
            if checked is not None:
                entry.Check(bool(checked))
            menu.Bind(wx.EVT_MENU, lambda event: self.guard(action), entry)
            return entry

        def live_submenu(parent, title, populate):
            menu = wx.Menu()
            populate(menu)
            parent.AppendSubMenu(menu, title)
            self._menu_populators[menu] = populate

        file = wx.Menu()
        item(file, "Add Audio Files…\tCtrl+O", self.add_audio_files)
        item(file, "Add Audio Folder…\tCtrl+Shift+O", self.add_audio_folder)
        file.AppendSeparator()
        item(file, "Settings…\tCtrl+,", self.show_settings)
        item(file, "Exit\tAlt+F4", self.Close)
        menubar.Append(file, "&File")

        view = wx.Menu()
        item(view, "Library\tCtrl+1", lambda: self.show_workspace(0))
        item(view, "Convert Files\tCtrl+3", lambda: self.show_workspace(1))
        item(view, "Downloads\tCtrl+2", self.show_transfers)
        view.AppendSeparator()
        item(view, "Find in Library\tCtrl+F", self.find_library)
        item(view, "Sort Library", self.library.show_sort)
        item(view, "Reverse Sort Order", self.library.reverse_sort)
        item(view, "Filter Library", self.library.show_filter)
        item(view, "Clear Filters", self.library.clear_filters)
        item(view, "Library Status…\tCtrl+Shift+S", self.library.show_library_status)
        view.AppendSeparator()
        self._view_checks = {
            key: item(view, label, lambda key=key: self.toggle(key), checked=self.settings[key])
            for key, label in (("show_sidebar", "Show Sidebar"), ("show_status", "Show Status Bar"))
        }
        item(view, "Show DownAudible\tCtrl+0", self.show_main_window)
        menubar.Append(view, "&View")

        books = wx.Menu()
        item(books, "Refresh Library\tCtrl+R", self.library.refresh)
        item(books, "Refresh All Accounts", lambda: self.library.refresh(all_accounts=True))
        item(books, "Library Changes…", self.library.show_library_changes)
        live_submenu(books, "Saved Views", self.library.populate_saved_views)
        item(books, "Recheck Saved Files", self.recheck_saved_files)
        item(books, "Select All Books\tCtrl+Shift+A", self.library.select_all)
        downloads = wx.Menu()
        item(downloads, "Download Selected\tCtrl+D", lambda: self.request_selected_downloads(self.library.selected_books()))
        item(downloads, "Download Selected As…\tCtrl+Alt+D", lambda: self.review_download(self.library.selected_books()))
        item(downloads, "Download Visible Results…", lambda: self.confirm_bulk_download(
            self.library.visible_books(), "Download Visible Results"))
        downloads.AppendSeparator()
        item(downloads, "Download Missing\tCtrl+Shift+D", self.request_missing_downloads)
        item(downloads, "Download Missing As…\tCtrl+Alt+Shift+D", lambda: self.request_missing_downloads(customizing=True))
        item(downloads, "Download Missing PDFs…", self.request_missing_pdfs)
        item(downloads, "Download Entire Library\tCtrl+Shift+L", lambda: self.confirm_bulk_download(
            self.library.books, "Download Entire Library"))
        item(downloads, "Download Entire Library As…\tCtrl+Alt+Shift+L", lambda: self.review_download(
            self.library.books))
        downloads.AppendSeparator()
        item(downloads, "Add Selected to Queue…", lambda: self.review_add(self.library.selected_books()))
        item(downloads, "Add Visible Results to Queue…", lambda: self.review_add(self.library.visible_books()))
        item(downloads, "Restart Selected Incomplete Downloads…", self.library.restart_selected_downloads)
        books.AppendSubMenu(downloads, "&Download")
        live_submenu(books, "Match Audio Files", self.library.populate_folder_actions)
        live_submenu(books, "Selected Books", lambda menu: self.library.populate_selected_book_actions(
            menu, self.library.selected_books()))
        item(books, "Edit Book…\tCtrl+E", self.edit_selected)
        item(books, "Verify and Repair Archive…", self.media_views.verify)
        item(books, "Export Library…", self.library.export_books)
        exports = wx.Menu()
        for extension in (".json", ".csv", ".tsv", ".xlsx"):
            caption = "Excel (.xlsx)…" if extension == ".xlsx" else f"{extension[1:].upper()}…"
            item(exports, caption, lambda extension=extension: self.library.export_books(extension=extension))
        books.AppendSubMenu(exports, "Export Library Format")
        item(books, "Export Visible Results…", lambda: self.library.export_books(True))
        item(books, "Export Visible Results to Goodreads…", self.library.export_to_goodreads)
        live_submenu(books, "Conversion", self.populate_conversion_menu)
        menubar.Append(books, "&Audiobooks")

        jobs = wx.Menu()
        self._transfer_commands = {
            key: item(jobs, label, lambda action=action: self.run_transfer_action(action))
            for key, label, action in (
                ("cancel", "Cancel Batch\tCtrl+.", self.queue.cancel),
                ("retry", "Retry Incomplete\tCtrl+Alt+R", self.transfers.retry),
                ("restart", "Restart Incomplete Downloads…\tCtrl+Alt+Shift+R", lambda: self.transfers.retry(restart=True)),
                ("clear", "Clear Completed\tCtrl+Alt+K", self.transfers.clear_completed),
            )
        }
        live_submenu(jobs, "Selected Transfers", lambda menu: self.transfers.populate_actions(menu, shortcut_labels=False))
        menubar.Append(jobs, "&Downloads")

        tools = wx.Menu()
        item(tools, "Audible Accounts…", self.library.manage_accounts)
        live_submenu(tools, "Account Actions", self.library.populate_account_actions)
        item(tools, "Audible Tools…", self.library.audible_tools)
        item(tools, "Wish List…", self.library.wishlist)
        item(tools, "Listening Statistics…", self.library.show_listening_stats)
        item(tools, "Check for Better-Quality Audio…", self.library.show_quality_audit)
        item(tools, "Audiobookshelf Uploads…", self.show_audiobookshelf)
        menubar.Append(tools, "&Tools")

        help_menu = wx.Menu()
        item(help_menu, "DownAudible Help\tF1", self.show_help)
        item(help_menu, "Keyboard Shortcuts", lambda: self.show_help(10))
        item(help_menu, "Settings Reference", lambda: self.show_help(12))
        item(help_menu, "Widevine Stereo", lambda: self.show_help(13))
        item(help_menu, "Audiobookshelf", lambda: self.show_help(14))
        item(help_menu, "Set Up DownAudible…", self.setup)
        item(help_menu, "Check for Updates…", self.check_updates)
        item(help_menu, "Donate…", lambda: wx.LaunchDefaultBrowser(DONATION))
        help_menu.AppendSeparator()
        item(help_menu, "About DownAudible", self.about)
        menubar.Append(help_menu, "&Help")
        self.SetMenuBar(menubar)
        self.refresh_transfer_menu()

    def refresh_open_menus(self, event):
        event.Skip()
        if event.IsPopup() or event.GetMenu() is None:
            return
        for key, entry in self._view_checks.items():
            entry.Check(self.settings[key])
        self.refresh_transfer_menu()
        # wxMSW sends one open event per menu-bar navigation, including moves between menus.
        for submenu, populate in self._menu_populators.items():
            for entry in submenu.GetMenuItems():
                submenu.Unbind(wx.EVT_MENU, id=entry.GetId())
                submenu.DestroyItem(entry)
            populate(submenu)

    def refresh_transfer_menu(self):
        busy = self.queue.pending
        batch = self.transfers.shown_batch()
        jobs = batch["jobs"] if batch else ()
        self._transfer_commands["cancel"].Enable(busy)
        self._transfer_commands["retry"].Enable(not busy and any(job["status"] in RETRYABLE for job in jobs))
        self._transfer_commands["restart"].Enable(not busy and any(self.transfers.can_restart(job, batch) for job in jobs))
        self._transfer_commands["clear"].Enable(not busy and any(job["status"] == "Completed" for job in jobs))

    def run_transfer_action(self, action):
        self.show_transfers()
        action()

    def populate_conversion_menu(self, menu):
        converter = self.converter
        selected = converter.selected_files()
        player_ready = any(audio.format in {"m4a", "m4b", "mp3"} for audio in selected)
        entries = (
            ("Conversion Options…", converter.conversion_options, True),
            ("Choose Destination…", converter.choose_destination, True),
            ("Convert Selected" if selected else "Convert All", converter.convert_selection, converter.convert_button.IsEnabled()),
            ("Edit Book…", converter.edit, converter.edit_button.IsEnabled()),
            ("Show in File Explorer", converter.reveal_selection, bool(selected)),
            ("Open Audio in Default Player", converter.open_selection, player_ready),
            ("Export CUE Sheet…", converter.export_cue, converter.can_export_cue()),
            ("Copy Path", converter.copy_paths, bool(selected)),
            ("Remove from List", converter.remove, bool(selected)),
            ("Clear List", converter.clear, converter.clear_button.IsEnabled()),
        )
        for caption, action, enabled in entries:
            self.library._menu_action(menu, caption, action, enabled)

    def toggle(self, key):
        current = self.settings[key]
        try:
            self.settings[key] = not current
            self.save_settings()
        except (OSError, ValueError):
            self.settings[key] = current
            self._view_checks[key].Check(current)
            raise
        self.library.update_status()

    def about(self):
        info = wx.adv.AboutDialogInfo()
        info.SetName("DownAudible")
        info.SetVersion(f"{VERSION} (build {RELEASE.build})")
        info.SetDescription("Download, archive and convert audiobooks from your Audible library.")
        info.SetCopyright("Copyright © Ashley Cox")
        info.SetWebSite(PROJECT, "DownAudible on GitHub")
        info.AddDeveloper("Ashley Cox")
        info.SetLicence("GNU Affero General Public License, version 3")
        wx.adv.AboutBox(info, self)

    def show_workspace(self, index, *, focus=True):
        self.sidebar.SetSelection(index)
        for position, page in enumerate(self.pages):
            page.Show(position == index)
        self.workspace.Layout()
        if index == 2:
            self.transfers.refresh()
            self.refresh_transfer_menu()
        if not focus:
            return
        if index == 2:
            self.transfers.list.SetFocus()
        elif index == 0:
            self.library.focus_workspace()
        else:
            self.converter.activate()

    def show_converter(self):
        self.show_workspace(1)

    def show_transfers(self):
        self.show_workspace(2)

    def find_library(self):
        self.show_workspace(0)
        self.library.focus_search()

    def add_audio_files(self):
        self.show_workspace(1)
        self.converter.add_files()

    def add_audio_folder(self):
        self.show_workspace(1)
        self.converter.add_folder()

    def downloadable_books(self, books):
        books = list(books)
        active = self.settings.get("audible_account")
        owners = {profile_id(book, active) for book in books}
        signed_in = {owner for owner in owners if self.library.is_signed_in(owner)}
        return [book for book in books if profile_id(book, active) in signed_in and (
            book.get("isDownloadable", True) or self.matched_files(book) or self.settings["existing_files"] == "reuse"
            and any(copy.original and copy.is_complete() for copy in self.archived_audio_copies(book)))]

    def bulk_download_dialog(self, title, count):
        noun = "book" if count == 1 else "books"
        dialog = wx.Dialog(self, title=title)
        layout = wx.BoxSizer(wx.VERTICAL)
        message = wx.StaticText(dialog, label=f"Download {count} {noun} using your saved download options?")
        layout.Add(message, 0, wx.ALL, 16)
        buttons = wx.StdDialogButtonSizer()
        cancel = wx.Button(dialog, wx.ID_CANCEL)
        download = wx.Button(dialog, wx.ID_OK, "Download")
        buttons.AddButton(cancel)
        buttons.AddButton(download)
        buttons.Realize()
        cancel.SetDefault()
        cancel.SetFocus()
        layout.Add(buttons, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 16)
        dialog.SetSizerAndFit(layout)
        dialog.CentreOnParent()
        return dialog

    def request_missing_downloads(self, *, customizing=False):
        scope = self.library.all_accounts, self.library.active_account_id
        if not self.library.browsing or self.queue.pending:
            self.set_status("Open an Audible library and wait for any active transfers before downloading missing audio.")
            return
        request = object()
        self._missing_download_request = request

        def finish():
            if self._missing_download_request is not request:
                return
            self._missing_download_request = None
            if self._closed or self.queue.pending or (self.library.all_accounts, self.library.active_account_id) != scope:
                return
            missing = self.library.missing_books()
            if not missing:
                self.set_status("Every downloadable title has a saved or matched audio file.")
            elif customizing:
                self.review_download(missing, ensure_audio=True)
            else:
                self.confirm_bulk_download(missing, "Download Missing", ensure_audio=True)

        self.recheck_saved_files(on_complete=finish)

    def request_missing_pdfs(self):
        if self.queue.pending:
            self.set_status("Wait for the current batch before downloading missing PDFs.")
            return
        self._load_receipts()
        root = self.selected_archive_root()
        candidates = [book for book in self.library.books if book.get("hasPDF") is True]
        fallback = self.library.active_account_id
        owners = {profile_id(book, fallback) for book in candidates}
        signed_in = {owner for owner in owners if self.library.is_signed_in(owner)}
        books = []
        for book in candidates:
            owner, asin = book_identity(book, fallback)
            saved = self._pdf_receipts.get((root, owner, asin), ())
            if owner in signed_in and not any(recorded_file(path, sizes) for path, sizes in saved):
                books.append(book)
        if not books:
            self.set_status("No missing PDFs for signed-in accounts in this library view.")
            return
        with wx.MessageDialog(self, f"Download missing companion PDFs for {len(books):,} books? Saved audio stays in place.",
                              "Download Missing PDFs", wx.YES_NO | wx.NO_DEFAULT | wx.ICON_QUESTION) as confirmation:
            confirmation.SetYesNoLabels("Download PDFs", "Cancel")
            if confirmation.ShowModal() == wx.ID_YES:
                self.enqueue_books(books, {**DEFAULT_DOWNLOAD, "downloadAudio": False, "downloadPDF": True}, pdf_backfill=True)

    def confirm_bulk_download(self, books, title, *, ensure_audio=False):
        eligible = self.downloadable_books(books)
        if not eligible:
            self.set_status("No downloadable books are available for this action.")
            return
        if self.queue.pending:
            self.review_add(eligible)
            return
        if not ensure_audio and not any(self.settings["download"][key] for key in CHECKED_DOWNLOAD_OUTPUTS):
            self.enqueue_books(eligible)
            return
        with self.bulk_download_dialog(title, len(eligible)) as dialog:
            if dialog.ShowModal() == wx.ID_OK:
                self.enqueue_books(eligible, {"downloadAudio": True} if ensure_audio else None)

    def request_selected_downloads(self, books):
        if self.queue.pending:
            self.review_add(books)
        elif len(books) > 1:
            self.confirm_bulk_download(books, "Download Selected")
        else:
            self.enqueue_books(books)

    def review_download(self, books, *, restart=False, ensure_audio=False):
        eligible = self.downloadable_books(books)
        if restart:
            eligible = [book for book in eligible if self.has_incomplete_download(book)]
        if not eligible:
            self.set_status("No partial audio is available to restart." if restart else "Select at least one downloadable book.")
            return
        if self.queue.pending:
            if restart:
                self.error("Wait for the current batch before restarting downloads.")
            else:
                self.review_add(eligible)
            return
        options = {"downloadAudio": True} if ensure_audio or restart else {}
        if restart:
            options["restart"] = True
        with DownloadDialog(self, eligible, options, "Restart Incomplete Downloads" if restart else "Download As") as dialog:
            if dialog.ShowModal() == wx.ID_OK and self.save_download_choices(dialog.options):
                self.enqueue_books(eligible, {"restart": restart})

    def save_download_choices(self, options):
        setting_keys = ("archive_root", "folder_template", "download")
        previous = {key: self.settings[key] for key in setting_keys}
        self.settings.update(archive_root=options["destination"], folder_template=options["folder_template"],
                             download={**self.settings["download"], **{key: options[key] for key in DEFAULT_DOWNLOAD}})
        try:
            self.save_settings()
        except OSError as error:
            self.settings.update(previous)
            self.error(str(error), "Download Options Could Not Be Saved")
            return False
        return True

    def can_add_downloads(self):
        return not self.library.all_accounts and self.queue.download_addition_state(self.library.active_account_id) is not None

    def download_queue_additions(self, books, state=None):
        if self.library.all_accounts:
            return []
        state = state or self.queue.download_addition_state(self.library.active_account_id)
        if state is None:
            return []
        _, existing = state
        loaded = {book["asin"] for book in self.library.books}
        unique = {book["asin"]: book for book in self.downloadable_books(books)}
        return [book for asin, book in unique.items() if asin in loaded and asin not in existing]

    def review_add(self, books):
        account = self.library.active_account_id
        state = self.queue.download_addition_state(account)
        if state is None:
            self.set_status("The current batch cannot accept more downloads from this account.")
            return
        eligible = self.download_queue_additions(books, state)
        if not eligible:
            self.set_status("No new downloadable books are available to add.")
            return
        with wx.MessageDialog(self, f"Add {len(eligible)} books using the current batch’s destination and options?",
                              "Add to Download Queue", wx.YES_NO | wx.ICON_QUESTION) as dialog:
            if dialog.ShowModal() == wx.ID_YES:
                current = self.queue.download_addition_state(account)
                if account != self.library.active_account_id or current is None or current[0] != state[0] or (
                    self.download_queue_additions(eligible, current) != eligible
                ):
                    self.error("The running batch changed or finished. Review the titles and try again.")
                    return
                self.enqueue_books(eligible, expected_batch=state[0])

    def enqueue_books(self, books, options=None, *, reveal=True, expected_batch=None, pdf_backfill=False, upgrade=False):
        defaults = self.settings["download"]
        if options and options.get("repair"):
            defaults = {**DEFAULT_DOWNLOAD, "convert": defaults["convert"], "keepOriginal": defaults["keepOriginal"]}
        options = {**deepcopy(defaults), **(options or {})}
        account = options.pop("account_id", None) or self.library.active_account_id
        restart = options.pop("restart", False)
        if not account:
            self.error("Connect an Audible account in Settings > Accounts before downloading.")
            return
        if expected_batch is None and not any(options[key] for key in CHECKED_DOWNLOAD_OUTPUTS):
            self.error("Use a Download As command or choose what to save in Downloads settings.", "Choose What to Download")
            return
        if pdf_backfill:
            eligible = [book for book in books if book.get("hasPDF") and self.library.is_signed_in(profile_id(book, account))]
        else:
            eligible = [book for book in self.downloadable_books(books) if not upgrade or book.get("isDownloadable") is True]
        unique = {book_identity(book, account): book for book in eligible}
        use_matches = not (restart or upgrade or options.get("repair"))
        jobs = [{
            "kind": "Download", "title": book["title"], "book": book, "options": options,
            "account_id": owner, "restart": restart, "pdf_backfill": pdf_backfill,
            "matched_sources": [str(path) for path in self.match_paths(book)] if use_matches else [],
        } for (owner, _asin), book in unique.items()]
        if jobs:
            settings = self.queue_settings()
            if upgrade:
                settings.update(existing_files="new", api={**settings["api"], "quality": upgrade["quality"],
                                                           "format": upgrade.get("format", "preferAAX")},
                                conversion={**settings["conversion"], "move_aax_to_trash": False},
                                prefer_widevine=upgrade.get("preferWidevine", False))
            elif pdf_backfill:
                settings["existing_files"] = "reuse"
            count = self.guard(self.queue.submit, jobs, settings, add=expected_batch is not None,
                               expected_batch=expected_batch)
            if count:
                if reveal:
                    self.show_transfers()
                return count
        else:
            self.set_status("No downloadable books are selected.")

    def queue_settings(self):
        excluded = {"matches", "match_folders", "automatic_matches", "audible_accounts", "audible_account", "library_sort",
                    "library_tags", "saved_library_views"}
        return {key: value for key, value in self.settings.items() if key not in excluded}

    def enqueue_conversion(self, paths, options=None):
        if isinstance(paths, (str, Path)):
            paths = [paths]
        options = dict(options or {})
        destination = options.pop("destination", None)
        code = options.pop("activation_bytes", None)
        jobs = []
        for source in paths:
            source = Path(source)
            job = dict(kind="Conversion", title=source.stem, source=str(source), options=options,
                       account_id=self.library.active_account_id)
            if destination:
                job["destination"] = str(destination)
            jobs.append(job)
        return self.submit_local_jobs(jobs, code)

    def enqueue_edit(self, path, data):
        data = dict(data)
        source = Path(path[0] if isinstance(path, (list, tuple)) else path)
        stat = source.stat()
        code = data.pop("activation_bytes", None)
        for key in SECRET_SETTINGS:
            data.pop(key, None)
        job = dict(data, kind="Edit", title=data.get("title", source.stem), source=str(source),
                   revision=[stat.st_size, stat.st_mtime_ns], account_id=self.library.active_account_id)
        return self.submit_local_jobs([job], code)

    def submit_local_jobs(self, jobs, activation_code):
        if not jobs:
            return False
        reference = None
        try:
            if activation_code:
                reference = "activation-" + uuid4().hex
                self.library.client.save_session(reference, activation_code)
                for job in jobs:
                    job["activation_reference"] = reference
            count = self.queue.submit(jobs, self.queue_settings())
        except (AudibleError, OSError, ValueError, RuntimeError) as error:
            if reference:
                self.guard(self.library.client.remove_session, reference)
            self.error(str(error) or type(error).__name__)
            return False
        if count:
            self.show_transfers()
        return bool(count)

    def edit_selected(self):
        if self.converter.IsShown():
            self.converter.edit()
            return
        books = self.library.selected_books()
        if len(books) == 1 and profile_id(books[0], self.library.active_account_id) == self.library.active_account_id:
            self.media_views.edit(books[0])
        else:
            self.set_status("Select one book to edit.")

    def receipt_audio_paths(self, book):
        return [file for copy in self.archived_audio_copies(book) if copy.is_complete() for file in copy.files]

    def selected_archive_root(self):
        configured = self.settings["archive_root"]
        cached = getattr(self, "_selected_archive_root", None)
        if cached is None or cached[0] != configured:
            cached = self._selected_archive_root = configured, Path(configured).resolve()
        return cached[1]

    def archived_audio_copies(self, book, *, root=None):
        if root is None:
            root = self.selected_archive_root()
        account = profile_id(book, self.settings.get("audible_account"))
        return self._receipts.get((root, account, book["asin"]), ())

    def archive_verification_matches(self, books, *, root=None):
        if root is None:
            root = self.selected_archive_root()
        groups = {}
        sizes = {}
        for book in books:
            matched = self.match_paths(book)
            copies = self.archived_audio_copies(book, root=root)
            groups[book["asin"]] = [*([matched] if matched else []), *(list(copy.files) for copy in copies)]
            for copy in copies:
                sizes.update(copy.sizes)
        return groups, sizes

    def files_for_book(self, book):
        return list(dict.fromkeys(self.matched_files(book) + self.receipt_audio_paths(book)))

    def matched_files(self, book):
        files = self.match_paths(book)
        return files if all(recorded_file(path, {}) for path in files) else []

    def missing_output_files(self, book):
        archived = {path for copy in self.archived_audio_copies(book) for path in copy.missing_files()}
        matched = {path for path in self.match_paths(book) if not recorded_file(path, {})}
        return sorted(archived | matched, key=lambda path: str(path).casefold())

    def match_paths(self, book):
        account = profile_id(book, self.settings.get("audible_account"))
        explicit = self.settings["matches"].get(account, {})
        automatic = self.settings.get("automatic_matches", {}).get(account, {})
        return [Path(value) for value in explicit.get(book["asin"], automatic.get(book["asin"], []))]

    def archive_matches(self, books=None):
        books = self.library.books if books is None else books
        return {book["asin"]: list(dict.fromkeys(self.matched_files(book) + self.receipt_audio_paths(book)))
                for book in books}

    def status_for(self, book):
        copies = self.archived_audio_copies(book)
        if any(copy.is_complete() for copy in copies):
            return "Downloaded"
        if self.matched_files(book):
            return "Matched"
        if self.has_incomplete_download(book):
            return "Incomplete"
        if copies or self.match_paths(book):
            return "Files missing"
        if self.demo:
            demo_status = {"DEMO000001": "Downloaded", "DEMO000003": "Matched", "DEMO000004": "Files missing"}.get(book["asin"])
            if demo_status:
                return demo_status
        return "Not downloaded" if book.get("isDownloadable", True) else "Unavailable"

    def has_incomplete_download(self, book):
        runner = getattr(self, "runner", None)
        if runner is None:
            return False
        return runner.has_partial({"kind": "Download", "book": book,
                                   "account_id": profile_id(book, self.settings.get("audible_account"))}, self.settings)

    def library_transfers(self):
        queue = getattr(self, "queue", None)
        current = queue.snapshot()["current"] if queue and queue.pending else None
        if not current:
            return {}
        statuses = {"Running": "In progress", "Waiting": "Queued"}
        return {(job.get("account_id"), job["book"]["asin"]): statuses[job["status"]] for job in current["jobs"]
                if job["kind"] == "Download" and job["status"] in statuses and job.get("options", {}).get("downloadAudio")}

    def _load_receipts(self):
        receipts = {}
        saved_pdfs = {}
        for entry in (self.data_dir / "Receipts").glob("*.json"):
            try:
                value = read_json(entry) or {}
                root, account, asin = (value.get(key) for key in ("root", "account_id", "asin"))
                if not root or not account or not asin:
                    continue
                root = Path(root).resolve()
                groups, sizes = value.get("groups", {}), value.get("sizes", {})
                if not isinstance(sizes, dict):
                    sizes = {}
                for filename in groups.get("pdf", ()):
                    path = Path(filename)
                    if path.is_relative_to(root) and path.suffix.casefold() == ".pdf":
                        saved_pdfs.setdefault((root, account, asin), []).append((path, sizes))
                for name in ("audio", "conversion"):
                    files = tuple(Path(file) for file in groups.get(name, ()))
                    if not files or not all(path.is_relative_to(root) for path in files):
                        continue
                    group_sizes = {str(path): sizes[str(path)] for path in files if str(path) in sizes}
                    copy = ArchiveCopy(files, group_sizes, original=name == "audio")
                    receipts.setdefault((root, account, asin), []).append(copy)
            except (ValueError, OSError, AttributeError, TypeError, RuntimeError):
                continue
        self._receipts = receipts
        self._pdf_receipts = saved_pdfs

    def matched_folder(self):
        if self.library.all_accounts:
            return None
        path = self.settings["match_folders"].get(self.library.active_account_id)
        return Path(path) if path else None

    def scan_archive(self, *, deliberate=False, on_complete=None):
        if self._closed:
            return
        if on_complete is not None:
            self._index_callbacks.append(on_complete)
        if self._index_pending:
            return
        directory = self.matched_folder()
        if not self.library.books or directory is None:
            self._complete_match_scan()
            return
        self._index_pending = True
        self._index_generation += 1
        generation = self._index_generation
        account = self.library.active_account_id
        books = self.library.books.copy()
        if deliberate:
            self.set_status("Matching audio files…")

        def index_files():
            try:
                matching = match_books(books, self.tools.scan(directory)) if directory.is_dir() else None
            except (OSError, ValueError):
                matching = None
            wx.CallAfter(self._receive_folder_matches, account, directory, generation, matching, deliberate)

        Thread(target=index_files, daemon=True, name="Archive index").start()

    def match_files(self, books, folder=False):
        account = self.library.active_account_id
        if not account:
            return
        if (folder and self.library.all_accounts) or any(profile_id(book, account) != account for book in books):
            self.set_status("Choose the book’s account in Library before matching audio.")
            return
        if not folder:
            if len(books) != 1:
                return
            with wx.FileDialog(self, "Match to Audio Files", wildcard="Audiobooks (*.m4b;*.m4a;*.mp3;*.aax;*.aaxc;*.aa)|*.m4b;*.m4a;*.mp3;*.aax;*.aaxc;*.aa",
                               style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST | wx.FD_MULTIPLE) as dialog:
                if dialog.ShowModal() != wx.ID_OK:
                    return
                paths = sorted(dialog.GetPaths(), key=lambda value: Path(value).name.casefold())
                self.settings["matches"].setdefault(account, {})[books[0]["asin"]] = paths
                self.save_settings()
                self.library.render()
                self.set_status("Matched one audiobook.")
                return
        default = str(self.matched_folder() or self.settings["archive_root"])
        with wx.DirDialog(self, "Match Existing Folder", defaultPath=default) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return
            directory = Path(dialog.GetPath())
        if directory != self.matched_folder():
            self._invalidate_match_scan()
            self.settings.setdefault("automatic_matches", {}).pop(account, None)
        self.settings["match_folders"][account] = str(directory)
        self.save_settings()
        self.library.render()
        self.scan_archive(deliberate=True)

    def _invalidate_match_scan(self):
        self._index_generation += 1
        self._index_pending = False

    def _receive_folder_matches(self, account, directory, generation, matching, deliberate):
        if self._closed or generation != self._index_generation:
            return
        self._index_pending = False
        if self.library.active_account_id != account or self.matched_folder() != directory:
            self.scan_archive()
            return
        if matching is None:
            if deliberate:
                self.set_status("Could not scan the matched folder. Check that it is available.")
            self._complete_match_scan()
            return
        automatic = self.settings.setdefault("automatic_matches", {})
        normalized = {asin: [str(path) for path in files] for asin, files in matching.items()}
        if automatic.get(account) != normalized:
            previous = automatic.get(account)
            automatic[account] = normalized
            try:
                self.save_settings()
            except OSError as error:
                if previous is None:
                    automatic.pop(account, None)
                else:
                    automatic[account] = previous
                self.error(str(error), "Could Not Save File Matches")
                self._complete_match_scan()
                return
        self.library.render()
        if deliberate:
            self.set_status(f"Found audio for {len(normalized)} audiobook(s).")
        self._complete_match_scan()

    def _complete_match_scan(self):
        callbacks, self._index_callbacks = self._index_callbacks, []
        for callback in callbacks:
            callback()

    def stop_matching_folder(self):
        account = self.library.active_account_id
        if self.matched_folder() is None:
            return
        self._invalidate_match_scan()
        self.settings["match_folders"].pop(account, None)
        self.settings.get("automatic_matches", {}).pop(account, None)
        self.save_settings()
        self.library.render()
        self.set_status("The matched folder has been disconnected.")
        self._complete_match_scan()

    def recheck_saved_files(self, *, on_complete=None):
        self._load_receipts()
        self.library.render()
        self.scan_archive(deliberate=True, on_complete=on_complete)

    def remove_matches(self, books=None):
        account = self.library.active_account_id
        if not account:
            return
        books = self.library.selected_books() if books is None else books
        if any(profile_id(book, account) != account for book in books):
            self.set_status("Choose the book’s account in Library before removing its file match.")
            return
        target = self.settings["matches"].setdefault(account, {})
        for book in books:
            target[book["asin"]] = []
        self.save_settings()
        self.library.render()

    def queue_changed(self):
        if not self._refresh_pending and not self._closed:
            self._refresh_pending = True
            wx.CallAfter(self._refresh_queue)

    def _refresh_queue(self):
        self._refresh_pending = False
        if self._closed:
            return
        state = self.queue.snapshot()
        self.transfers.refresh(state)
        self.refresh_transfer_menu()
        if getattr(self, "converter", None) is not None:
            self.converter.refresh_actions()
        summary = tuple((job["id"], job["status"]) for job in state["current"]["jobs"]) if state["current"] else ()
        if summary != getattr(self, "_last_queue_summary", None):
            self._last_queue_summary = summary
            self._load_receipts()
            self.library.render()
        if self.queue.persistence_error:
            self.set_status("The transfer queue could not be saved.")
        if self._restart_for_update and not self.queue.pending and not self._exit_pending:
            self.Close()

    def finish_batch(self, batch_id, events, _settings):
        if self._closed:
            return
        self._load_receipts()
        self.library.render()
        state = self.queue.snapshot()
        batch = next((item for item in (state["current"], *state["history"]) if item and item["id"] == batch_id), None)
        if batch is None or not any(job["status"] in {"Completed", "Warning", "Failed"} for job in batch["jobs"]):
            return
        sounds = []
        for event, label in FEEDBACK_EVENTS.items():
            identifiers = events.get(event, ())
            if event != "queueFinished" and not identifiers:
                continue
            config = self.settings["notifications"].get(event, {})
            delivery = config.get("delivery", "off")
            if delivery in {"notificationOnly", "both"} and identifiers:
                jobs = [job for job in batch["jobs"] if job["id"] in identifiers]
                message = jobs[0]["title"] if len(jobs) == 1 else f"{len(identifiers):,} jobs. Open Downloads for details."
                self.notify(message, label,
                            on_click=lambda b=batch_id, i=identifiers: self.open_notification(b, i))
            if delivery in {"soundOnly", "both"}:
                sounds.append((config.get("sound", "softBell"), config.get("custom_sound", self.settings.get("custom_sound", ""))))
        self._feedback_sounds.extend(sounds)
        if self._feedback_timer is None:
            self._play_next_feedback()

    def _play_next_feedback(self):
        self._feedback_timer = None
        if self._closed:
            return
        while self._feedback_sounds:
            if delay := self.play_sound(*self._feedback_sounds.popleft()):
                self._feedback_timer = wx.CallLater(delay + 30, self._play_next_feedback)
                return

    def open_notification(self, batch_id, identifiers):
        if self._closed:
            return
        self.transfers.active_batch = batch_id
        self.show_transfers()
        first = None
        for index, job in enumerate(self.transfers.rows):
            selected = job["id"] in identifiers
            self.transfers.list.Select(index, selected)
            if first is None and selected:
                first = index
        if first is not None:
            self.transfers.list.Focus(first)
            self.transfers.list.EnsureVisible(first)
            self.transfers.list.SetFocus()
        self.show_main_window()

    def show_main_window(self):
        if self.IsIconized():
            self.Iconize(False)
        self.Show()
        self.Raise()

    def sounds(self):
        return {
            "softBell": "Soft Bell", "wind": "Airy Sweep", "brightPing": "Bright Ping",
            "fallingNotes": "Falling Notes", "gentlePulse": "Gentle Pulse", "marimba": "Marimba",
            "risingNotes": "Rising Notes", "twoTone": "Two Tone", "warmChord": "Warm Chord", "woodTap": "Wood Tap",
        }

    def play_sound(self, key, custom=""):
        sound_path = self.resource_dir / "Sounds" / f"Completion-{key if key != 'wind' else 'airySweep'}.wav"
        if not sound_path.exists() and sys.platform == "darwin":
            sound_path = ROOT.parent / "DownAudible" / "Resources" / sound_path.name
        if key == "custom" and custom:
            sound_path = Path(custom)
        if key == "system":
            wx.Bell()
            return 600
        length = duration_ms(sound_path)
        if length and wx.adv.Sound.Play(str(sound_path), wx.adv.SOUND_ASYNC):
            return length
        return 0

    def notify(self, message, title="DownAudible", on_click=None):
        if self.test_mode:
            self.set_status(message)
            return
        notice = wx.adv.NotificationMessage(title, message, parent=self)
        token = id(notice)

        def release(_event, *, clicked=False):
            retained = self._notifications.pop(token, None)
            if clicked and retained is not None and on_click and not self._closed:
                on_click()

        notice.Bind(wx.adv.EVT_NOTIFICATION_MESSAGE_CLICK, lambda event: release(event, clicked=True))
        notice.Bind(wx.adv.EVT_NOTIFICATION_MESSAGE_DISMISSED, release)
        self._notifications[token] = notice
        if notice.Show():
            self.set_status(message)
        else:
            self._notifications.pop(token, None)
            self.set_status("Windows could not show the notification. Check Windows notification settings.")

    def open_notification_settings(self):
        if os.name == "nt":
            os.startfile("ms-settings:notifications")
        else:
            self.set_status("Windows notification settings are available in Windows.")

    def show_help(self, chapter=None):
        if self._help_root is None:
            bundled = self.resource_dir / "Help"
            if (bundled / "README.html").is_file():
                self._help_root = bundled
            else:
                source = self.resource_dir / "Manual"
                if not source.is_dir():
                    source = ROOT / "Manual"
                self._help_root = build_help(source, self.data_dir / "Help").parent
        path = self._help_root / "README.html"
        if chapter is not None:
            matches = (list(self._help_root.glob(f"help-{chapter:02d}-*.html")) if isinstance(chapter, int)
                       else list(self._help_root.glob(f"*{chapter}*.html")))
            if matches:
                path = matches[0]
        wx.LaunchDefaultBrowser(path.resolve().as_uri())

    def open_file(self, path):
        if os.name == "nt":
            os.startfile(Path(path))
        else:
            wx.LaunchDefaultApplication(str(path))

    def show_file(self, path):
        if os.name == "nt":
            subprocess.Popen(["explorer.exe", f"/select,{Path(path)}"])
        else:
            subprocess.Popen(["open", "-R", str(path)])

    def _update_dialog(self, title, text, confirm, decline):
        dialog = wx.Dialog(self, title=title)
        layout = wx.BoxSizer(wx.VERTICAL)
        message = wx.StaticText(dialog, label=text)
        message.Wrap(dialog.FromDIP(360))
        layout.Add(message, 0, wx.ALL, 16)
        accept = wx.Button(dialog, wx.ID_OK, confirm)
        reject = wx.Button(dialog, wx.ID_NO, decline)
        reject.Bind(wx.EVT_BUTTON, lambda event: dialog.EndModal(wx.ID_NO))
        buttons = wx.StdDialogButtonSizer()
        buttons.AddButton(reject)
        buttons.AddButton(accept)
        buttons.Realize()
        reject.SetDefault()
        reject.SetFocus()
        layout.Add(buttons, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 16)
        dialog.SetSizerAndFit(layout)
        dialog.CentreOnParent()
        return dialog

    def update_choice_dialog(self):
        return self._update_dialog("Check for Updates Automatically", "Allow DownAudible to check for updates automatically?",
                                   "Check Automatically", "Don’t Check")

    def start_update_checks(self):
        if self._closed or not self.settings["setup_complete"]:
            return
        if not self.settings["update_choice_made"]:
            with self.update_choice_dialog() as dialog:
                answer = dialog.ShowModal()
            if answer not in {wx.ID_OK, wx.ID_NO}:
                return
            self.settings.update(update_choice_made=True, check_updates=answer == wx.ID_OK)
            try:
                self.save_settings()
            except OSError as error:
                self.settings.update(update_choice_made=False, check_updates=False)
                self.error(str(error), "Update Settings Could Not Be Saved")
                return
        if self.settings["check_updates"]:
            self.check_updates(quiet=True)

    def check_updates(self, quiet=False):
        if self.demo:
            self.set_status("The demo session uses sample data and does not contact GitHub.")
            return
        if self._update_checking:
            self.set_status("DownAudible is checking for updates…")
            return
        self._update_checking = True
        if not quiet:
            self.set_status("Checking for updates…")

        def check():
            try:
                update = check_update(VERSION, running_windows_architecture())
                wx.CallAfter(self._update_result, update, quiet)
            except UpdateError as error:
                wx.CallAfter(self._update_error, str(error), quiet)

        Thread(target=check, daemon=True, name="Update check").start()

    def update_publisher(self):
        if os.name != "nt" or self.demo or not (self.resource_dir.parent / "Uninstall.exe").is_file():
            return ""
        try:
            return (self.resource_dir / "UpdatePublisher.txt").read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def _update_error(self, message, quiet):
        self._update_checking = False
        if not self._closed and not quiet:
            self.error(message, "DownAudible Update")

    def _update_result(self, update, quiet):
        self._update_checking = False
        if self._closed:
            return
        if update is None:
            if not quiet:
                self.notify("No newer Windows installer was found.", "DownAudible Update")
            return
        publisher = self.update_publisher()
        if quiet and publisher and self.settings["check_updates"] and self.settings["install_updates"]:
            self._download_update(update, publisher, restart=False)
        else:
            self._offer_update(update, publisher)

    def update_available_dialog(self, version, can_install):
        message = f"DownAudible {version} is available for Windows."
        if can_install:
            message += " DownAudible will finish any active transfers before installing the update and reopening."
            action = "Download and Install"
        else:
            message += " Open the release page to get the new version."
            action = "Open Release Page"
        return self._update_dialog("DownAudible Update", message, action, "Later")

    def _offer_update(self, update, publisher):
        with self.update_available_dialog(update.version, bool(publisher)) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return
        if publisher:
            self._download_update(update, publisher, restart=True)
        else:
            wx.LaunchDefaultBrowser(update.release_url)

    def _download_update(self, update, publisher, *, restart):
        installer = self._staged_update
        if self._staged_release == update and installer and installer.is_file():
            if restart:
                self._update_staged(update, installer, restart)
            return
        self._staged_update = None
        self._staged_release = None
        self._restart_for_update = False
        self._update_checking = True
        if restart:
            self.set_status(f"Downloading DownAudible {update.version}…")

        def stage():
            try:
                installer = download_verified(update, self.data_dir / "Updates", expected_publisher=publisher)
                wx.CallAfter(self._update_staged, update, installer, restart)
            except UpdateError as error:
                wx.CallAfter(self._update_error, str(error), not restart)

        Thread(target=stage, daemon=True, name="Update download").start()

    def _update_staged(self, update, installer, restart):
        self._update_checking = False
        if self._closed:
            return
        self._staged_update = installer
        self._staged_release = update
        if restart:
            self._restart_for_update = True
            if self.queue.pending:
                self.set_status("The update will install after the current transfers finish.")
            else:
                self.Close()
        elif self.settings["check_updates"] and self.settings["install_updates"]:
            self.notify(f"DownAudible {update.version} is ready to install when you exit.", "DownAudible Update")

    def install_on_exit(self, *, restart):
        automatic = self.settings["check_updates"] and self.settings["install_updates"]
        if not self._staged_update or not (automatic or restart):
            return True
        launcher = os.environ.get("DOWNAUDIBLE_LAUNCHER_PID", "")
        if not launcher.isdecimal():
            self.error("DownAudible could not locate the installed app’s launcher.", "DownAudible Update")
            return False
        try:
            self.queue.save()
        except OSError as error:
            self.error(f"DownAudible could not save its transfer queue before updating.\n\n{error}",
                       "DownAudible Update")
            return False
        try:
            schedule_verified_install(self._staged_update, self.resource_dir.parent, expected_publisher=self.update_publisher(),
                                      launcher_pid=int(launcher), restart=restart)
        except UpdateError as error:
            self.error(str(error), "DownAudible Update")
            return False
        return True

    def on_close(self, event):
        active = self.queue.active
        can_veto = event.CanVeto()
        if self._exit_pending and can_veto:
            event.Veto()
            return
        if self.queue.pending and can_veto and not self.test_mode:
            with wx.MessageDialog(self, "A batch has unfinished work. Save your progress and exit DownAudible?",
                                  "Exit DownAudible", wx.YES_NO | wx.NO_DEFAULT | wx.ICON_QUESTION) as dialog:
                dialog.SetYesNoLabels("Exit and Save Progress", "Keep DownAudible Open")
                if dialog.ShowModal() != wx.ID_YES:
                    event.Veto()
                    return
            event.Veto()
            save = True
            while True:
                try:
                    self.queue.prepare_close(save=save)
                    break
                except OSError as error:
                    choice = self._quit_save_choice(error)
                    if choice == wx.ID_CANCEL:
                        return
                    save = choice == wx.ID_YES
            self._exit_pending = True
            self.set_status("Stopping transfers and saving progress…" if save else "Stopping transfers…")
            wx.CallLater(100, self._finish_transfer_close, save)
            return
        if self.library.save_columns():
            self.guard(self.save_settings)
        if can_veto and not active and not self._exit_without_saving:
            restart = self._restart_for_update
            self._restart_for_update = False
            if not self.install_on_exit(restart=restart) and restart:
                self.queue.reopen()
                event.Veto()
                return
        self._closed = True
        self.library.close_catalogue()
        self.watcher.Stop()
        self.update_timer.Stop()
        if hasattr(self, "audiobookshelf"):
            self.audiobookshelf.close()
        if self.queue.pending:
            self.queue.cancel(closing=True)
        self.queue.close()
        event.Skip()

    def _quit_save_choice(self, error):
        with wx.MessageDialog(self, f"DownAudible could not save the transfer queue.\n\n{error}",
                              "Could Not Save Progress", wx.YES_NO | wx.CANCEL | wx.CANCEL_DEFAULT | wx.ICON_WARNING) as dialog:
            dialog.SetYesNoCancelLabels("Try Saving Again", "Exit Without Saving", "Keep DownAudible Open")
            return dialog.ShowModal()

    def _finish_transfer_close(self, save):
        if self._closed:
            return
        if self.queue.active:
            wx.CallLater(100, self._finish_transfer_close, save)
            return
        while save:
            try:
                self.queue.save()
                break
            except OSError as error:
                choice = self._quit_save_choice(error)
                if choice == wx.ID_CANCEL:
                    self.queue.reopen()
                    self._exit_pending = False
                    self.set_status("DownAudible is still open. Retry interrupted transfers from Downloads.")
                    return
                save = choice == wx.ID_YES
        self._exit_pending = False
        self._exit_without_saving = not save
        self.Close()


def arguments():
    parser = argparse.ArgumentParser(description="DownAudible for Windows")
    parser.add_argument("--demo", action="store_true", help="Use synthetic data in an isolated profile.")
    parser.add_argument("--data-dir", type=Path, help="Use an alternate profile directory.")
    parser.add_argument("--capture-help", type=Path, help="Capture the manual using synthetic data.")
    parser.add_argument("--smoke-test", type=Path, help="Write a local synthetic verification report.")
    return parser.parse_args()


def main():
    args = arguments()
    demo = args.demo or args.capture_help is not None or args.smoke_test is not None
    if args.data_dir is not None:
        data = args.data_dir.resolve()
    elif demo:
        data = Path(tempfile.mkdtemp(prefix="DownAudible-Demo-"))
    else:
        data = app_data()
    data.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=data / "Application.log", level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", encoding="utf-8")
    app = wx.App(False)
    app.SetAppName("DownAudible")
    app.SetVendorName("Ashley Cox")
    profile_key = stable_id(os.path.normcase(str(data.resolve())))[:32]
    profile_lock = wx.SingleInstanceChecker(f"DownAudible-{profile_key}", str(data))
    if profile_lock.IsAnotherRunning():
        message = "DownAudible is already open for this profile."
        if args.capture_help or args.smoke_test:
            raise RuntimeError(message)
        wx.MessageBox(message, "DownAudible", wx.OK | wx.ICON_INFORMATION)
        return
    if os.name == "nt" and not demo:
        wx.adv.NotificationMessage.MSWUseToasts("DownAudible.lnk", "AshleyCox.DownAudible")
    try:
        frame = MainFrame(data, default_resources(), demo=demo,
                          test_mode=args.capture_help is not None or args.smoke_test is not None)
        app.SetTopWindow(frame)
        frame.Show()
        if args.capture_help or args.smoke_test:
            from .capture import run_capture, run_smoke
            if args.capture_help:
                wx.CallLater(750, run_capture, frame, args.capture_help, args.smoke_test)
            else:
                wx.CallLater(750, run_smoke, frame, args.smoke_test)
        elif not frame.settings["setup_complete"] and not demo:
            wx.CallAfter(frame.setup)
        app.MainLoop()
    except Exception:
        LOG.exception("DownAudible could not start")
        raise


if __name__ == "__main__":
    main()

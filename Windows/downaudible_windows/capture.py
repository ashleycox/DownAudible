"""Reproduce the manual captures and an offline Windows smoke test."""

import logging
import os
import traceback
from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path
from time import monotonic

import wx

from .audible_dialogs import (
    ANDROID_BROWSER,
    ENTER_CREDENTIALS,
    WEB_BROWSER,
    DeviceRegistrationDialog,
    ImportAccountDialog,
    SignInDialog,
    VerificationDialog,
    WidevineDialog,
)
from .audible_tools import CatalogDialog
from .audiobookshelf import UploadBook, UploadEntry, UploadTarget
from .audiobookshelf_views import ShelfUploadsDialog
from .helpbook import build_help
from .insights import (
    ListeningStatisticsDialog,
    QualityAuditDialog,
    QualityRow,
    TitleCheckDialog,
)
from .jobs import demo_audio
from .library import LibraryFilterDialog
from .media import LocalAudio
from .media_views import ArchiveVerificationDialog, BookEditor
from .reading_views import AnnotationsDialog, GoodreadsDialog
from .refusal import RetryAfter
from .settings_views import PAGES, SettingsDialog, SetupDialog, place_dialog
from .state import write_json
from .transfer_views import DownloadDialog

LOG = logging.getLogger(__name__)


def capture_window(window, destination):
    wx.YieldIfNeeded()
    if os.name == "nt":
        return _print_windows_window(window, destination)
    rect = window.GetScreenRect()
    if rect.width <= 0 or rect.height <= 0:
        raise RuntimeError("The capture window is not visible.")
    bmp = wx.Bitmap(rect.width, rect.height)
    memory = wx.MemoryDC(bmp)
    screen = wx.ScreenDC()
    if not memory.Blit(0, 0, rect.width, rect.height, screen, rect.x, rect.y):
        raise RuntimeError("Could not read the Windows desktop for the manual capture.")
    memory.SelectObject(wx.NullBitmap)
    if not bmp.SaveFile(str(destination), wx.BITMAP_TYPE_PNG):
        raise OSError(f"Could not save {destination.name}.")


def _print_windows_window(window, destination):
    import ctypes
    from ctypes import wintypes

    from PIL import Image

    class BitmapInfo(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("width", wintypes.LONG), ("height", wintypes.LONG),
                    ("planes", wintypes.WORD), ("bit_count", wintypes.WORD), ("compression", wintypes.DWORD),
                    ("image_size", wintypes.DWORD), ("x_ppm", wintypes.LONG), ("y_ppm", wintypes.LONG),
                    ("colors", wintypes.DWORD), ("important_colors", wintypes.DWORD), ("palette", wintypes.DWORD)]

    def bind(library, name, result, *arguments):
        function = getattr(library, name)
        function.restype = result
        function.argtypes = arguments
        return function

    user, gdi = ctypes.windll.user32, ctypes.windll.gdi32
    hwnd = window.GetHandle()
    rect = wintypes.RECT()
    get_rect = bind(user, "GetWindowRect", wintypes.BOOL, wintypes.HWND, ctypes.POINTER(wintypes.RECT))
    if not get_rect(hwnd, ctypes.byref(rect)):
        raise OSError("Could not determine the window bounds.")
    width, height = rect.right - rect.left, rect.bottom - rect.top
    get_dc = bind(user, "GetDC", wintypes.HDC, wintypes.HWND)
    release_dc = bind(user, "ReleaseDC", ctypes.c_int, wintypes.HWND, wintypes.HDC)
    compatible_dc = bind(gdi, "CreateCompatibleDC", wintypes.HDC, wintypes.HDC)
    create_bitmap = bind(gdi, "CreateCompatibleBitmap", wintypes.HBITMAP, wintypes.HDC, ctypes.c_int, ctypes.c_int)
    select = bind(gdi, "SelectObject", wintypes.HGDIOBJ, wintypes.HDC, wintypes.HGDIOBJ)
    delete = bind(gdi, "DeleteObject", wintypes.BOOL, wintypes.HGDIOBJ)
    delete_dc = bind(gdi, "DeleteDC", wintypes.BOOL, wintypes.HDC)
    print_window = bind(user, "PrintWindow", wintypes.BOOL, wintypes.HWND, wintypes.HDC, wintypes.UINT)
    get_pixels = bind(gdi, "GetDIBits", ctypes.c_int, wintypes.HDC, wintypes.HBITMAP, wintypes.UINT,
                      wintypes.UINT, ctypes.c_void_p, ctypes.POINTER(BitmapInfo), wintypes.UINT)
    screen = get_dc(None)
    context = compatible_dc(screen)
    bitmap = create_bitmap(screen, width, height)
    original = select(context, bitmap)
    try:
        if not print_window(hwnd, context, 2):
            raise OSError("Windows could not render the requested app window.")
        select(context, original)
        info = BitmapInfo(40, width, -height, 1, 32, 0, width * height * 4)
        pixels = ctypes.create_string_buffer(width * height * 4)
        if get_pixels(screen, bitmap, 0, height, pixels, ctypes.byref(info), 0) != height:
            raise OSError("Could not read the rendered Windows window.")
        image = Image.frombytes("RGB", (width, height), pixels.raw, "raw", "BGRX")
        frame = wintypes.RECT()
        border = bind(ctypes.windll.dwmapi, "DwmGetWindowAttribute", ctypes.c_long, wintypes.HWND,
                      wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD)
        if border(hwnd, 9, ctypes.byref(frame), ctypes.sizeof(frame)) == 0:
            coordinates = (frame.left - rect.left, frame.top - rect.top, frame.right - rect.left, frame.bottom - rect.top)
            if 0 <= coordinates[0] < coordinates[2] <= width and 0 <= coordinates[1] < coordinates[3] <= height:
                image = image.crop(coordinates)
        image.save(destination)
    finally:
        select(context, original)
        delete(bitmap)
        delete_dc(context)
        release_dc(None, screen)


def _fixture_frame(frame):
    work = wx.Display(wx.Display.GetFromWindow(frame)).GetClientArea()
    size = (min(work.width - 30, 1200), min(work.height - 24, 700))
    frame.SetSize(size)
    frame.SetPosition((work.x + (work.width - size[0]) // 2, work.y + 10))
    frame.Raise()
    frame.SetFocus()
    return work


def _in_front(dialog, work):
    width, height = dialog.GetSize()
    width, height = min(width, work.width - 12), min(height, work.height - 12)
    dialog.SetSize((width, height))
    dialog.SetPosition((work.x + (work.width - width) // 2, work.y + (work.height - height) // 2))
    dialog.Show()
    dialog.Raise()
    return dialog


def run_capture(frame, directory, smoke=None):
    directory.mkdir(parents=True, exist_ok=True)
    work = _fixture_frame(frame)

    def fail(error):
        LOG.exception("Manual capture failed", exc_info=error)
        (directory / "capture-error.txt").write_text(traceback.format_exc(), encoding="utf-8")
        frame.Close()

    def prepare():
        local = frame.data_dir / "Sample Audio" / "Demo Book 3.m4b"
        local = demo_audio(frame.tools.ffmpeg, local, "Demo Book 3")
        frame.settings.setdefault("matches", {}).setdefault("demo-account", {})["DEMO000003"] = [str(local)]
        now = datetime.now(timezone.utc).isoformat()
        demo_jobs = [
            dict(id=str(index), kind=kind, title=f"Demo Book {index}", status=status,
                 detail=detail, progress=None, files=[str(local)] if index == 1 else [],
                 book=frame.library.books[index - 1], account_id="demo-account",
                 options={"downloadAudio": kind == "Download"})
            for index, (kind, status, detail) in enumerate([
                ("Download", "Completed", "Audio and companion files saved"),
                ("Download", "Failed", "The connection ended before the download finished."),
                ("Conversion", "Interrupted", "Retry to resume this job."),
                ("Download", "Warning", "Companion PDF unavailable."),
            ], 1)
        ]
        frame.queue.state["current"] = {"id": "capture", "date": now, "jobs": demo_jobs, "settings": frame.queue_settings()}
        return local

    try:
        synthetic_audio = prepare()
        frame.show_workspace(0)
    except Exception as error:
        fail(error)
        return

    def library_search():
        frame.library.search.SetValue("Demo Book 3")
        frame.library.focus_search()
        return frame

    def selected_library():
        frame.library.list.Select(0)
        frame.library.list.Focus(0)
        return frame

    demo_accounts = frame.settings["audible_accounts"]
    demo_account = frame.settings["audible_account"]

    def all_accounts_library():
        frame.library.all_accounts = True
        frame.library.update_accounts()
        frame.library.show_cached_catalogue()
        return frame

    def single_account_library():
        frame.library.all_accounts = False
        frame.library.update_accounts()
        frame.library.show_cached_catalogue()

    def library_changes():
        sample = frame.library.catalogue.get(demo_account)
        previous = sample["changes"]
        sample["changes"] = [{"change": "Added", "title": "Demo Book 6"},
                             {"change": "No longer listed", "title": "Demo Book 9"}]
        try:
            return frame.library.library_changes_dialog()
        finally:
            sample["changes"] = previous

    def signed_out_library():
        frame.settings["audible_accounts"] = []
        frame.settings["audible_account"] = None
        frame.library.signed_in = False
        frame.library.update_accounts()
        frame.library.show_cached_catalogue()
        return frame

    def restore_login():
        frame.settings["audible_accounts"] = demo_accounts
        frame.settings["audible_account"] = demo_account
        frame.library.signed_in = True
        frame.library.update_accounts()
        frame.library.show_cached_catalogue()

    def reset_library():
        frame.library.search.ChangeValue("")
        frame.library.render()

    def failed_library():
        frame.library.books = []
        frame.library.render()
        frame.library.show_fetch_error("Could not reach Audible. Check your connection and try again.")
        return frame

    def restore_library():
        frame.library.books = sample_books
        frame.library._fetch_error = False
        frame.library._fetch_message = ""
        frame.library.update_visibility()
        frame.library.render()

    def empty_accounts():
        accounts = frame.settings["audible_accounts"]
        frame.settings["audible_accounts"] = []
        try:
            return frame.library.manage_accounts()
        finally:
            frame.settings["audible_accounts"] = accounts

    def sign_in(method=WEB_BROWSER):
        dialog = SignInDialog(frame, frame.library)
        dialog.method.SetSelection(method)
        dialog.sync_method()
        if method != ENTER_CREDENTIALS:
            dialog.open_browser()
        return dialog

    def sign_in_verification():
        from PIL import Image, ImageDraw, ImageFont

        picture = Image.new("RGB", (285, 85), "#f7f6f0")
        drawing = ImageDraw.Draw(picture)
        drawing.line((6, 62, 279, 23), fill="#a0adb4", width=2)
        drawing.text((142, 42), "SAMPLE", anchor="mm", font=ImageFont.load_default(size=39), fill="#11293c")
        buffer = BytesIO()
        picture.save(buffer, format="PNG")
        return VerificationDialog(frame, "captcha", "https://example.com/verification", buffer.getvalue())

    def import_account():
        dialog = ImportAccountDialog(frame, frame.library)
        dialog.password.SetValue("password12345")
        return dialog

    def import_open_audible():
        dialog = ImportAccountDialog(frame, frame.library)
        dialog.mode.SetSelection(ImportAccountDialog.OPEN_AUDIBLE)
        dialog.sync_mode()
        dialog.path.ChangeValue(r"C:\Demo\OpenAudible\credentials.json")
        dialog.load_profiles()
        return dialog

    def activation():
        dialog = frame.library.audible_tools()
        dialog.tabs.SetSelection(1)
        dialog.fetch_activation()
        return dialog

    def title_check():
        account = demo_accounts[0]
        return TitleCheckDialog(frame, frame.library.client, account, sample_books[2],
                                frame.library.title_offer_options(account))

    def quality_audit():
        account = demo_accounts[0]
        sample = sample_books[2]
        dialog = QualityAuditDialog(frame, frame.library.client, account, [(sample, [synthetic_audio])],
                                    frame.library.title_offer_options(account), lambda _books: None)
        # Present a completed audit with a comparable pair of stereo audio sources.
        dialog.checked(([QualityRow(sample, "AAC LC · 64 kbps · 2 channels",
                                    "AAX · AAC-LC · 128 kbps · 2 channels", True)], ""))
        dialog.unbusy()
        dialog.table.Select(0)
        dialog.update_queue()
        return dialog

    def listening_statistics():
        dialog = ListeningStatisticsDialog(frame, frame.library.client, demo_accounts[0], demo_accounts)
        dialog.start_year.SetValue(2025)
        dialog.load()
        return dialog

    def annotations():
        return AnnotationsDialog(frame, frame.library.client, demo_accounts[0]["id"], sample_books[2],
                                 frame.library.library_options(), account_name=demo_accounts[0]["name"])

    def goodreads():
        return GoodreadsDialog(frame, [
            dict(sample_books[0], isbn="9781234567897", isFinished=True),
            dict(sample_books[1], percentComplete=42),
            dict(sample_books[2], asin="", isbn=None),
        ])

    def converter():
        frame.show_converter()
        frame.converter.add_paths([synthetic_audio])
        return frame

    def book_editor():
        book = frame.library.books[2]
        return BookEditor(frame, [synthetic_audio], book=book)

    def book_chapter_repair():
        chapter_file = synthetic_audio.with_name("Demo Book 3 Chapters.json")
        write_json(chapter_file, {"content_metadata": {"chapter_info": {
            "runtime_length_ms": 4000, "brandIntroDurationMs": 1000, "brandOutroDurationMs": 1000,
            "chapters": [{"start_offset_ms": 0, "length_ms": 4000, "title": "Chapter 1"}],
        }}})
        dialog = book_editor()

        def apply_when_ready(attempts=20):
            if dialog.layout and not dialog.work.running:
                dialog._repair_chapters(file=str(chapter_file), separate=True)
            elif attempts:
                wx.CallLater(75, apply_when_ready, attempts - 1)

        wx.CallLater(100, apply_when_ready)
        return dialog

    def select_output():
        frame.converter.list.Select(0)
        return frame

    reveal_file = frame.show_file

    def converter_cue():
        frame.show_file = lambda _path: None
        frame.converter.export_cue()
        return frame

    def restore_cue():
        frame.show_file = reveal_file
        frame.set_status("Ready")

    def converter_aax():
        fixture = synthetic_audio.with_name("Demo Book 4.aax")
        frame.converter.files.append(LocalAudio(fixture, "aax", None, "Demo Book 4", "Demo Author 2", 2340))
        frame.converter._render_files({fixture})
        frame.converter.status.SetLabel(frame.converter._file_count())
        frame.converter.activation.SetValue("12345678")
        return frame

    def restore_converter():
        frame.converter.activation.ChangeValue("")
        frame.converter.remove()

    def mp3_settings():
        original = frame.settings["conversion"]
        frame.settings["conversion"] = dict(original, format="mp3", mp3_bitrate_mode="variable")
        try:
            return SettingsDialog(frame, "Conversion")
        finally:
            frame.settings["conversion"] = original

    def archive_report():
        return ArchiveVerificationDialog(frame, frame.library.books,
                                         lambda cancel: {"DEMO000003": [synthetic_audio]},
                                         on_repair=lambda books: False)

    def retry_activation():
        frame.show_transfers()
        dialog = frame.transfers.activation_dialog()
        dialog.SetValue("12345678")
        return dialog

    def pacing_settings():
        original = frame.settings["daily_download_limit"]
        frame.settings["daily_download_limit"] = {"scope": "all", "unit": "books", "quantity": 10}
        try:
            return SettingsDialog(frame, "Jobs")
        finally:
            frame.settings["daily_download_limit"] = original

    transfers = frame.queue.state["current"]["jobs"]

    def paced_transfers():
        resumes = datetime.now().astimezone() + timedelta(hours=2)
        jobs = transfers[:1] + [dict(transfers[1], status="Waiting", pacing_until=resumes.timestamp(),
                                     detail=f"Daily limit reached. Resumes {resumes:%d %b %Y at %H:%M}.")]
        frame.queue.state["current"]["jobs"] = jobs
        frame.show_transfers()
        return frame

    def restore_transfers():
        frame.queue.state["current"]["jobs"] = transfers

    def refused_transfers():
        retry = datetime.now().astimezone() + timedelta(minutes=15)
        jobs = transfers[:1] + [dict(transfers[1], status="Waiting", refusal_until=retry.timestamp(),
                                     detail=RetryAfter(retry.timestamp(), "Audible is receiving too many requests.").detail())]
        frame.queue.state["current"]["jobs"] = jobs
        frame.show_transfers()
        return frame

    def shelf_settings():
        previous = frame.settings["audiobookshelf"]
        frame.settings["audiobookshelf"] = {
            "server": "https://books.example.com", "library_id": "sample", "folder_id": "audiobooks",
            "library_name": "Audiobooks", "folder_name": "/audiobooks", "auto_upload": True, "include_pdf": False,
        }
        try:
            dialog = SettingsDialog(frame, "Audiobookshelf")
            dialog.pages[PAGES.index("Audiobookshelf")].shelf.token.SetValue("example-api-token")
            return dialog
        finally:
            frame.settings["audiobookshelf"] = previous

    def shelf_uploads():
        target = UploadTarget("https://books.example.com", "sample", "audiobooks", "Audiobooks", "/audiobooks")
        queue = frame.audiobookshelf
        queue.configure(target, "")
        date = datetime.now(timezone.utc).timestamp()
        queue.entries = [
            UploadEntry("demo-failed", target, UploadBook.prepare(frame.library.books[1], [synthetic_audio]), False,
                        date, "Failed", "DownAudible could not reach Audiobookshelf."),
            UploadEntry("demo-sent", target, UploadBook.prepare(frame.library.books[2], [synthetic_audio]), False,
                        date, "Sent", "Sent to server"),
        ]
        return ShelfUploadsDialog(frame, position=place_dialog)

    def restore_shelf():
        frame.audiobookshelf.entries = []
        frame.configure_audiobookshelf()

    def export_account():
        tools = frame.library.audible_tools()
        def modal():
            tools.export_account()
        wx.CallAfter(modal)
        return tools

    sample_books = frame.library.books
    actions = [
        ("library", selected_library, None, 350),
        ("library-all-accounts", all_accounts_library, single_account_library, 350),
        ("library-changes", library_changes, None, 350),
        ("library-search", library_search, reset_library, 350),
        ("library-filter", lambda: LibraryFilterDialog(frame, "authors", "Author", "Demo Au",
                                                       ["Demo Author 1", "Demo Author 2"]), None, 350),
        ("library-signed-out", signed_out_library, restore_login, 400),
        ("library-load-error", failed_library, restore_library, 350),
        ("setup-welcome", lambda: SetupDialog(frame), None, 350),
        ("setup-accounts", lambda: SetupDialog(frame, PAGES.index("Accounts")), None, 350),
        ("setup-finish", lambda: SetupDialog(frame, len(PAGES)), None, 350),
        ("update-choice", frame.update_choice_dialog, None, 350),
        ("update-available", lambda: frame.update_available_dialog("1.2.3", True), None, 350),
        ("accounts-empty", empty_accounts, None, 350),
        ("accounts", frame.library.manage_accounts, None, 350),
        ("accounts-device", lambda: DeviceRegistrationDialog(frame, frame.library, demo_accounts[0], "demo",
                                                               {"kind": "android", "name": "Demo Device",
                                                                "marketplace": "uk", "serialSuffix": "F123"}), None, 350),
        ("accounts-widevine", lambda: WidevineDialog(frame, frame.library, demo_accounts[0]), None, 350),
        ("sign-in-browser", lambda: sign_in(), None, 350),
        ("sign-in-android", lambda: sign_in(ANDROID_BROWSER), None, 350),
        ("sign-in-credentials", lambda: sign_in(ENTER_CREDENTIALS), None, 350),
        ("sign-in-verification", sign_in_verification, None, 350),
        ("import-account", import_account, None, 600),
        ("import-openaudible", import_open_audible, None, 600),
        ("library-status", frame.library.show_library_status, None, 450),
        ("download-options", lambda: DownloadDialog(frame, [frame.library.books[1]]), None, 400),
        ("download-visible-results", lambda: frame.bulk_download_dialog("Download Visible Results", 3), None, 400),
        ("audible-wishlist", frame.library.wishlist, None, 700),
        ("audible-catalogue", lambda: CatalogDialog(frame, frame.library.client, frame.library.active_account_id), None, 700),
        ("audible-activation", activation, None, 750),
        ("audible-export", export_account, None, 750),
        ("audible-title-check", title_check, None, 750),
        ("audible-quality-audit", quality_audit, None, 450),
        ("audible-listening-statistics", listening_statistics, None, 750),
        ("audible-annotations", annotations, None, 750),
        ("library-goodreads-export", goodreads, None, 450),
        ("converter", converter, None, 800),
        ("converter-selected", select_output, None, 350),
        ("converter-cue", converter_cue, restore_cue, 750),
        ("converter-aax", converter_aax, restore_converter, 350),
        ("book-editor", book_editor, None, 900),
        ("book-chapter-repair", book_chapter_repair, None, 2200),
        ("book-editor-download", lambda: BookEditor(frame, [], book=frame.library.books[4]), None, 350),
        ("archive-verification", archive_report, None, 900),
        ("transfers", lambda: (frame.show_transfers(), frame)[1], None, 450),
        ("transfers-pacing", paced_transfers, restore_transfers, 400),
        ("transfers-refusal", refused_transfers, restore_transfers, 400),
        ("retry-activation", retry_activation, None, 350),
        *[(f"settings-{page.lower()}", lambda page=page: SettingsDialog(frame, page), None, 400)
          for page in PAGES if page != "Audiobookshelf"],
        ("settings-audiobookshelf", shelf_settings, None, 400),
        ("audiobookshelf-uploads", shelf_uploads, restore_shelf, 400),
        ("jobs-pacing", pacing_settings, None, 400),
        ("conversion-mp3", mp3_settings, None, 400),
    ]

    def next_action():
        if not actions:
            (directory / "capture-complete.txt").write_text("Manual captures used synthetic data.\n", encoding="utf-8")
            if smoke:
                run_smoke(frame, smoke)
            else:
                frame.Close()
            return
        name, create, complete, delay = actions.pop(0)
        try:
            window = create()
            if window is not frame:
                _in_front(window, work)
        except Exception as error:
            fail(error)
            return

        def save():
            try:
                target = window
                if name == "audible-export":
                    target = next(item for item in wx.GetTopLevelWindows()
                                  if item.IsShown() and item.GetTitle() == "Export Encrypted Account File")
                    _in_front(target, work)
                if name == "book-editor" and target.sections.GetItemCount():
                    target.sections.CheckItem(0, False)
                if name == "book-chapter-repair" and not target.chapter_repair:
                    raise RuntimeError(target.status.GetLabel())
                if name == "archive-verification" and target.issues:
                    target.select_all()
                if name == "audible-catalogue" and target.list.GetItemCount():
                    target.list.Select(target.list.GetItemCount() - 1)
                if name == "audible-annotations" and target.table.GetItemCount() > 1:
                    target.table.Select(1)
                    target.show_detail()
                capture_window(target, directory / f"{name}.png")
                if target is not window:
                    target.EndModal(wx.ID_CANCEL)
                if window is not frame:
                    for key, value in list(frame.library._windows.items()):
                        if window is value:
                            del frame.library._windows[key]
                    window.Destroy()
                if complete:
                    complete()
            except Exception as error:
                fail(error)
                return
            wx.CallLater(90, next_action)
        wx.CallLater(delay, save)
    next_action()


def run_smoke(frame, report):
    report.parent.mkdir(parents=True, exist_ok=True)
    results = {}
    deadline = monotonic() + 45

    def conclude(error=None):
        if error:
            results["error"] = str(error)
            LOG.error("Smoke test failed: %s", error)
        write_json(report, results)
        frame.Close()

    try:
        results["platform"] = wx.Platform
        assert len(frame.library.visible_books()) == 6
        frame.library.search.SetValue("Demo Book 3")
        assert len(frame.library.visible_books()) == 1
        frame.library.search.SetValue("")
        results["library_filter"] = True
        bar = frame.GetMenuBar()
        view = bar.GetMenu(bar.FindMenu("View"))
        book_menu = bar.GetMenu(bar.FindMenu("Audiobooks"))
        selected = book_menu.FindItemById(book_menu.FindItem("Selected Books")).GetSubMenu()
        for selection in (False, True):
            frame.library.list.Select(0, selection)
            frame.ProcessEvent(wx.MenuEvent(wx.wxEVT_MENU_OPEN, 0, view))
            copy_title = selected.FindItemById(selected.FindItem("Copy Title"))
            assert copy_title.IsEnabled() == selection
        results["live_menu_actions"] = True
        if not frame.transfers.rows:
            assert not any(item.IsEnabled() for item in frame._transfer_commands.values())
            results["empty_queue_commands_disabled"] = True
        with SettingsDialog(frame, "Files") as settings:
            assert settings.notebook.GetPageCount() == len(PAGES)
        results["settings_pages"] = len(PAGES)
        build_help(frame.resource_dir / "Manual", frame.data_dir / "Help")
        results["manual_pages"] = len(list((frame.data_dir / "Help").glob("help-*.html")))
        frame.settings["archive_root"] = str(frame.data_dir / "Smoke Archive")
        source = frame.data_dir / "Sample Audio" / "Synthetic Audiobook.m4b"
        demo_audio(frame.tools.ffmpeg, source, "Synthetic Audiobook")
        results["generated_audio"] = bool(frame.tools.probe(source).audio)
        frame.enqueue_books([frame.library.books[1]], {"convert": True, "downloadChapters": True})
    except Exception as error:
        conclude(error)
        return

    def poll():
        try:
            if frame.queue.active and monotonic() < deadline:
                wx.CallLater(200, poll)
                return
            current = frame.queue.snapshot()["current"]
            jobs = current["jobs"] if current else []
            if not jobs or jobs[0]["status"] != "Completed":
                raise RuntimeError(jobs[0]["detail"] if jobs else "The synthetic download was not queued.")
            first = jobs[0]
            outputs = [Path(file) for file in first["files"]]
            formats = {file.suffix.casefold() for file in outputs if file.is_file()}
            assert {".m4a", ".m4b", ".json"} <= formats, formats
            audio = next(path for path in outputs if path.suffix == ".m4b")
            probe = frame.tools.probe(audio)
            assert probe.audio.get("codec_name") == "aac"
            results["download_conversion_and_chapters"] = True
            results["queue_persisted"] = (frame.data_dir / "Queue.json").is_file()
            conclude()
        except Exception as error:
            conclude(error)
    wx.CallLater(150, poll)

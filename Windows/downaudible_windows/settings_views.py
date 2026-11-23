"""Native Settings and Setup share these controls."""

from contextlib import ExitStack, contextmanager
from copy import deepcopy
from pathlib import Path

import wx
from wx.lib.wordwrap import wordwrap

from .archive import ArchiveLayout
from .audiobookshelf_views import ShelfSettings
from .media import SAMPLE_RATES, ConversionOptions
from .notification_sounds import import_notification_sound
from .pacing import MAX_LIMIT, DownloadLimit
from .purchase_dates import (
    parse_purchase_date,
    purchase_date_options,
    purchase_date_text,
)
from .state import (
    DEFAULT_FOLDER_TEMPLATE,
    FEEDBACK_EVENTS,
    OPEN_AFTER_SAVING,
    native_folder_template,
)

PAGES = ("General", "Accounts", "Library", "Downloads", "Conversion", "Files", "Jobs", "Notifications", "Audiobookshelf")

DOWNLOAD_CHOICES = (
    ("downloadAudio", "Download audio"), ("convert", "Convert audio"),
    ("keepOriginal", "Keep the original after conversion"),
    ("downloadPDF", "Download companion PDFs"), ("downloadCover", "Save cover images"),
    ("downloadChapters", "Save chapters as JSON"), ("downloadAnnotations", "Save annotations as JSON"),
)
DOWNLOAD_TOOLTIPS = {
    "downloadAudio": "Save audiobook audio. Turn this off to save only the companion files you select.",
    "convert": "Convert downloaded audio using the current Conversion settings.",
    "keepOriginal": "Save the original Audible audio alongside the converted copy.",
    "downloadPDF": "Save any PDF Audible supplies with the book.",
    "downloadCover": "Save cover art as a separate image file.",
    "downloadChapters": "Save Audible’s chapter list as a separate JSON file.",
    "downloadAnnotations": "Save the account’s notes and bookmarks for the book as JSON.",
}
COVER_SIZES = (252, 315, 360, 408, 500, 558, 570, 882, 900, 1215)
DELIVERIES = [("off", "Off"), ("notificationOnly", "Notification Only"),
              ("soundOnly", "Sound Only"), ("both", "Both")]


def labeled(control, text):
    name = text.replace("&", "")
    control.SetName(name)
    if wx.Platform == "__WXMSW__":
        control.SetAccessibleName(name)
    return control


def wrap_text(control, text, width):
    dc = wx.ClientDC(control)
    dc.SetFont(control.GetFont())
    control.SetLabel(wordwrap(text, width, dc))


def place_dialog(dialog, parent, preferred, minimum):
    display = wx.Display.GetFromWindow(parent)
    work = wx.Display(0 if display == wx.NOT_FOUND else display).GetClientArea()
    margin = dialog.FromDIP(24)
    available_width = max(1, work.width - margin)
    available_height = max(1, work.height - margin)
    width = min(dialog.FromDIP(preferred[0]), available_width)
    height = min(dialog.FromDIP(preferred[1]), available_height)
    dialog.SetMinSize((
        min(dialog.FromDIP(minimum[0]), width),
        min(dialog.FromDIP(minimum[1]), height),
    ))
    dialog.SetSize((width, height))
    dialog.CentreOnParent()
    x, y = dialog.GetPosition()
    dialog.SetPosition((
        max(work.x, min(x, work.x + work.width - width)),
        max(work.y, min(y, work.y + work.height - height)),
    ))


@contextmanager
def save_settings_changes(frame):
    settings = frame.settings
    before = deepcopy(settings)
    try:
        yield
        frame.save_settings()
    except Exception:
        for key in settings.keys() - before.keys():
            del settings[key]
        for key, value in before.items():
            current = settings.get(key)
            if isinstance(current, dict) and isinstance(value, dict):
                current.clear()
                current.update(value)
            else:
                settings[key] = value
        raise


class Form(wx.ScrolledWindow):
    def __init__(self, parent, *, bordered=False):
        super().__init__(parent, style=wx.VSCROLL | (wx.BORDER_SIMPLE if bordered else wx.BORDER_NONE))
        self.SetScrollRate(0, self.FromDIP(16))
        self.layout = wx.BoxSizer(wx.VERTICAL)
        self.SetSizer(self.layout)
        self.bindings = []
        self.rows = []
        self.notes = []
        self.inset = self.FromDIP(14)
        self.row_gap = self.FromDIP(8)
        self.content_width = None

    def heading(self, title):
        label = wx.StaticText(self, label=title)
        label.SetFont(label.GetFont().Bold())
        gap = self.FromDIP(16) if self.layout.GetItemCount() else self.inset
        self.layout.AddSpacer(gap)
        self.layout.Add(label, 0, wx.LEFT | wx.RIGHT, self.inset)

    def note(self, message):
        item = wx.StaticText(self, label=message)
        self.notes.append((item, message))
        self.add_row(item, wx.EXPAND)
        return item

    def add_row(self, item, flags=0):
        self.layout.AddSpacer(self.row_gap)
        self.layout.Add(item, 0, flags | wx.LEFT | wx.RIGHT, self.inset)

    def row(self, name, control, *trailing, expand=True, accessible_label=None):
        label = name.GetLabel()
        row = wx.BoxSizer(wx.HORIZONTAL)
        fields = wx.BoxSizer(wx.HORIZONTAL)
        label_item = row.Add(name, 0, wx.ALIGN_CENTER_VERTICAL)
        field_item = row.Add(fields, 1, wx.ALIGN_CENTER_VERTICAL)
        fields.Add(labeled(control, accessible_label or label), int(expand), wx.ALIGN_CENTER_VERTICAL)
        for item in trailing:
            fields.Add(item, 0, wx.LEFT | wx.ALIGN_CENTER_VERTICAL, self.FromDIP(6))
        self.rows.append((row, name, label, label_item, field_item))
        self.add_row(row, wx.EXPAND)
        return control

    def check(self, data, key, label):
        item = wx.CheckBox(self, label=label)
        item.SetValue(bool(data.get(key)))
        self.add_row(item)
        self.bindings.append((data, key, item.GetValue))
        return item

    def choice(self, data, key, label, choices):
        values, names = zip(*choices, strict=True)
        caption = wx.StaticText(self, label=label)
        control = self.row(caption, wx.Choice(self, choices=names))
        control.SetSelection(values.index(data[key]) if data.get(key) in values else 0)
        self.bindings.append((data, key, lambda: values[control.GetSelection()]))
        return control

    def number(self, data, key, label, low, high, *, accessible_label=None):
        # Windows uses the preceding static label for the spin control's edit field.
        caption = wx.StaticText(self, label=label)
        initial = max(low, min(high, int(data.get(key, low))))
        control = wx.SpinCtrl(self, min=low, max=high, initial=initial)
        control.SetMinSize((self.FromDIP(108), -1))
        self.row(caption, control, expand=False, accessible_label=accessible_label)
        self.bindings.append((data, key, control.GetValue))
        return control

    def text(self, data, key, label, *, getter=None, value=None):
        caption = wx.StaticText(self, label=label)
        control = self.row(caption, wx.TextCtrl(self, value=str(data.get(key, "") if value is None else value)))
        self.bindings.append((data, key, lambda: getter(control.GetValue()) if getter else control.GetValue()))
        return control

    def button(self, label, action):
        button = wx.Button(self, label=label)
        button.Bind(wx.EVT_BUTTON, lambda event: action())
        self.add_row(button)
        return button

    def choose_path(self, data, key, label, *, folder=False, wildcard="All files (*.*)|*.*"):
        caption = wx.StaticText(self, label=label)
        field = wx.TextCtrl(self, value=str(data.get(key, "")))
        choose = wx.Button(self, label="Choose…")
        choose.SetName(f"Choose {label}")
        def browse(event):
            if folder:
                dialog = wx.DirDialog(self, label, defaultPath=field.GetValue(), style=wx.DD_DEFAULT_STYLE)
            else:
                dialog = wx.FileDialog(self, label, wildcard=wildcard, style=wx.FD_SAVE)
            with dialog:
                if dialog.ShowModal() == wx.ID_OK:
                    field.SetValue(dialog.GetPath())
        choose.Bind(wx.EVT_BUTTON, browse)
        self.row(caption, field, choose)
        self.bindings.append((data, key, field.GetValue))
        return field

    def apply(self):
        values = [(data, key, read()) for data, key, read in self.bindings]
        for data, key, value in values:
            data[key] = value

    def values_for(self, settings):
        return {**settings, **{key: read() for data, key, read in self.bindings if data is settings}}

    def complete(self):
        self.layout.AddSpacer(self.inset)
        self.Bind(wx.EVT_SIZE, self.resize_rows)
        self.fit_rows()

    def resize_rows(self, event):
        self.fit_rows()
        event.Skip()

    def fit_rows(self):
        width = self.GetClientSize().width - 2 * self.inset
        if width < self.FromDIP(100):
            width = self.FromDIP(600)
        if width == self.content_width:
            return
        self.content_width = width
        stacked = width < self.FromDIP(475)
        label_width = width if stacked else self.FromDIP(198)
        for row, name, label, label_item, field_item in self.rows:
            row.SetOrientation(wx.VERTICAL if stacked else wx.HORIZONTAL)
            name.SetMinSize(wx.DefaultSize)
            wrap_text(name, label, label_width)
            if not stacked:
                name.SetMinSize((label_width, -1))
            label_item.SetFlag(wx.BOTTOM if stacked else wx.RIGHT | wx.ALIGN_CENTER_VERTICAL)
            label_item.SetBorder(self.FromDIP(4 if stacked else 12))
            field_item.SetProportion(0 if stacked else 1)
            field_item.SetFlag(wx.EXPAND if stacked else wx.ALIGN_CENTER_VERTICAL)
        for note, message in self.notes:
            wrap_text(note, message, width)
        self.Layout()
        self.FitInside()


class SettingsPage(Form):
    def __init__(self, parent, frame, title, *, preview_conversion=None):
        super().__init__(parent)
        self.frame = frame
        self.settings = frame.settings
        self.title = title
        self.preview_conversion = preview_conversion or (lambda: self.settings["conversion"])
        self.SetName(title)
        getattr(self, title.lower())()
        self.complete()

    def audiobookshelf(self):
        self.shelf = ShelfSettings(self)

    def general(self):
        self.heading("Software Update")
        checking = self.check(self.settings, "check_updates", "Check for updates automatically")
        checking.SetToolTip("Periodically check for a new version of DownAudible.")
        install = self.check(self.settings, "install_updates", "Install updates automatically")
        publisher = bool(self.frame.update_publisher())
        install.Enable(publisher and checking.IsChecked())
        install.SetToolTip("Automatically install verified updates when DownAudible exits. A signed Windows installation is required.")

        def update_checking(event):
            install.Enable(publisher and checking.IsChecked())
            self.update_choice_made = True

        self.update_choice_made = self.settings["update_choice_made"]
        self.bindings.append((self.settings, "update_choice_made", lambda: self.update_choice_made))
        checking.Bind(wx.EVT_CHECKBOX, update_checking)
        self.button("Check for Updates…", self.frame.check_updates).SetToolTip("Check for a new version now.")
        self.heading("Interface")
        self.check(self.settings, "show_help_tags", "Show Tooltips").SetToolTip(
            "Show descriptions when you point to DownAudible controls."
        )

    def accounts(self):
        self.heading("Audible Accounts")
        self.note("Manage saved accounts and choose the account to use in the Library.")
        self.button("Manage Audible Accounts…", self.frame.library.manage_accounts).SetToolTip(
            "Switch, rename, or remove a saved Audible account."
        )
        self.button("Add Account…", self.frame.library.add_account).SetToolTip("Sign in to another Audible account.")
        self.button("Import Account…", self.frame.library.import_account).SetToolTip(
            "Use a saved Audible CLI or OpenAudible sign-in."
        )

    def library(self):
        api = self.settings["api"]
        self.heading("Library requests")
        self.choice(api, "podcasts", "Podcasts", [("ignore", "Hide podcasts"), ("showSeries", "Show podcast series"),
                                                 ("resolveEpisodes", "Show individual episodes")]).SetToolTip(
            "Hide podcasts or include podcast series or individual episodes when loading the library."
        )
        self.number(api, "pageSize", "Items per request", 10, 1000).SetToolTip(
            "Set the number of library titles requested at a time. DownAudible keeps loading matching titles."
        )
        self.text(api, "purchaseStart", "Purchased on or after (YYYY-MM-DD)",
                  value=purchase_date_text(api.get("purchaseStart")), getter=parse_purchase_date).SetToolTip(
            "Include purchases from the start of this date in your local time. Leave blank for no start date."
        )
        self.text(api, "purchaseEnd", "Purchased on or before (YYYY-MM-DD)",
                  value=purchase_date_text(api.get("purchaseEnd")), getter=parse_purchase_date).SetToolTip(
            "Include purchases through the end of this date in your local time. Leave blank for no end date."
        )
        self.heading("Browse")
        self.check(self.settings, "background_library_refresh", "Refresh signed-in accounts in the background").SetToolTip(
            "Refresh each signed-in Audible library every 30 minutes while DownAudible is open."
        )
        self.check(self.settings, "filter_suggestions", "Suggest values for library filters").SetToolTip(
            "Offer titles, authors, and other matching values from the current library in filter fields."
        )

    def downloads(self):
        self.heading("Audio and companion files")
        self.download_controls()
        self.cover_controls()

    def download_controls(self):
        download, api = self.settings["download"], self.settings["api"]
        controls = {}
        for key, label in DOWNLOAD_CHOICES:
            if key == "convert":
                label = f"Convert to {self.settings['conversion']['format'].upper()}"
            controls[key] = self.check(download, key, label)
            controls[key].SetToolTip(DOWNLOAD_TOOLTIPS[key])
        audio_format = self.choice(
            api, "format", "Download format", [("preferAAX", "AAX with fallback"), ("aaxOnly", "AAX only"), ("aaxcOnly", "AAXC")],
        )
        audio_format.SetToolTip("Choose whether to request AAX, AAXC, or AAX with fallback.")
        quality = self.choice(
            api, "quality", "Download quality", [("best", "Best"), ("high", "High"), ("normal", "Normal")],
        )
        quality.SetToolTip("Choose the audio quality DownAudible requests from Audible.")
        whole_book = self.check(api, "preferWholeBookDownloads", "Prefer whole-book downloads")
        whole_book.SetToolTip("Ask for the whole book before requesting individual parts.")
        chapters = self.choice(
            api, "chapterStyle", "Chapter file layout", [("tree", "Nested chapters"), ("flat", "Flat chapter list")],
        )
        chapters.SetToolTip("Choose whether the chapter JSON has a flat list or nested chapter groups.")
        self.choice(download, "open_after_saving", "Open after saving", OPEN_AFTER_SAVING).SetToolTip(
            "Choose which saved audio to open in the Windows app associated with its file format."
        )

        def update_controls(_event=None):
            audio_enabled = controls["downloadAudio"].IsChecked()
            for control in (audio_format, quality, whole_book, controls["convert"]):
                control.Enable(audio_enabled)
            controls["keepOriginal"].Enable(audio_enabled and controls["convert"].IsChecked())
            chapters.Enable(controls["downloadChapters"].IsChecked())

        for key in ("downloadAudio", "convert", "downloadChapters"):
            controls[key].Bind(wx.EVT_CHECKBOX, update_controls)
        update_controls()

    def cover_controls(self):
        self.heading("Cover sizes")
        api = self.settings["api"]
        current = set(api.get("coverSizes", []))
        controls = wx.CheckListBox(self, choices=[f"{size} pixels" for size in COVER_SIZES],
                                   size=(-1, self.FromDIP(105)))
        labeled(controls, "Cover sizes")
        controls.SetToolTip("Request cover art at the selected sizes.")
        controls.SetCheckedItems([index for index, size in enumerate(COVER_SIZES) if size in current])
        self.add_row(controls, wx.EXPAND)
        self.bindings.append((api, "coverSizes", lambda: [COVER_SIZES[index] for index in controls.GetCheckedItems()]))
        def select_largest():
            controls.SetCheckedItems([])
            largest.Disable()

        largest = self.button("Use Largest Available", select_largest)
        largest.SetToolTip("Clear specific cover sizes to request the largest available image.")
        largest.Enable(bool(controls.GetCheckedItems()))
        controls.Bind(wx.EVT_CHECKLISTBOX, lambda _event: largest.Enable(bool(controls.GetCheckedItems())))

    def conversion(self):
        profile = self.settings["conversion"]
        self.heading("File format and chapters")
        file_format = self.choice(profile, "format", "File format", [(value, value.upper()) for value in ("m4b", "m4a", "mp3")])
        file_format.SetToolTip("Use M4B for audiobook players, M4A for general audio players, or MP3 for broad compatibility.")
        chapters = self.choice(profile, "chapter_mode", "Chapters", [("single", "One file"), ("separate", "Separate chapter files")])
        chapters.SetToolTip("Save a single audiobook file or a separate file for each chapter.")
        markers = self.check(profile, "embed_chapters", "Keep chapter markers")
        markers.SetToolTip("Add chapter navigation when chapter information is available.")
        copy_chapters = self.check(profile, "copy_chapter_audio", "Copy chapter audio when possible")
        copy_chapters.SetToolTip("Split compatible AAC into chapter files without encoding it again.")
        self.heading("Audio and metadata")
        encoding = self.choice(profile, "audio_mode", "Encoding",
                               [("automatic", "Copy audio when possible"), ("encode", "Always encode")])
        encoding.SetToolTip("Copy compatible source audio or encode a new audio stream.")
        mp3_mode = self.choice(profile, "mp3_bitrate_mode", "MP3 bitrate mode",
                               [("automatic", "Automatic"), ("constant", "Constant (CBR)"), ("variable", "Variable (VBR)")])
        mp3_mode.SetToolTip("Choose how bitrate is set for MP3 exports.")
        quality_options = [(0, "Highest quality (V0)"), (2, "High quality (V2)"), (4, "Medium quality (V4)"),
                           (6, "Smaller file (V6)"), (8, "Smallest file (V8)")]
        previous_quality = profile.get("mp3_quality", 2)
        if previous_quality in range(10) and previous_quality not in dict(quality_options):
            quality_options.append((previous_quality, f"Custom quality (V{previous_quality})"))
        quality = self.choice(profile, "mp3_quality", "MP3 variable bitrate quality", quality_options)
        quality.SetToolTip("Choose the quality of variable-bitrate MP3 audio. A lower number gives higher quality.")
        bitrate = self.choice(profile, "bitrate", "Bitrate",
                              [(0, "Automatic"), *((kbps, f"{kbps} kbps") for kbps in (32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320))])
        bitrate.SetToolTip("Choose how much data each second of encoded audio uses.")
        channels = self.choice(profile, "channels", "Channels", [(0, "Match source"), (1, "Mono"), (2, "Stereo")])
        channels.SetToolTip("Keep source channels or encode as mono or stereo.")
        sample_rate = self.choice(profile, "sample_rate", "Sample rate",
                                  [(0, "Match source"), *((hz, f"{hz / 1000:g} kHz") for hz in SAMPLE_RATES)])
        sample_rate.SetToolTip("Keep the source sampling rate or choose one for your player.")
        warning = self.note("Choose a lower bitrate or a higher sample rate for these audio settings.")
        self.check(profile, "preserve_metadata", "Keep book metadata").SetToolTip(
            "Write details such as title, author, and narrator into the converted file."
        )
        self.check(profile, "embed_artwork", "Embed cover image").SetToolTip(
            "Include the cover image in the converted audio file."
        )
        recycle = self.check(profile, "move_aax_to_trash", "Move converted local AAX files to the Recycle Bin")
        recycle.SetToolTip("Move the AAX source to the Recycle Bin after the complete MP3 export is saved.")

        def sync_controls(event=None):
            selected = ConversionOptions.read(self.values_for(profile))
            single = selected.chapter_mode == "single"
            mp3 = selected.format == "mp3"
            markers.Enable(single)
            encoding.Enable(single)
            copy_chapters.Enable(selected.can_copy_chapter_audio)
            mp3_mode.Enable(mp3)
            quality.Enable(selected.variable_mp3)
            bitrate.Enable(not selected.variable_mp3)
            recycle.Enable(mp3)
            warning.Show(selected.has_incompatible_bitrate)
            self.Layout()
            self.FitInside()

        for control in (file_format, chapters, mp3_mode, bitrate, channels, sample_rate):
            control.Bind(wx.EVT_CHOICE, sync_controls)
        sync_controls()

    def files(self):
        self.heading("Destination")
        root = self.choose_path(self.settings, "archive_root", "Save to", folder=True)
        root.SetToolTip("Choose the folder where DownAudible saves audiobooks.")
        folder = self.text(self.settings, "folder_template", "Folder template",
                           value=native_folder_template(self.settings["folder_template"]), getter=native_folder_template)
        folder.SetToolTip("Use a backslash between folder names. Tokens such as format, author, and title vary by book.")
        self.button("Restore Default Template", lambda: folder.SetValue(DEFAULT_FOLDER_TEMPLATE)).SetToolTip(
            "Restore DownAudible’s default folder template."
        )
        self.heading("Filename rules")
        self.check(self.settings, "keep_aax_filename", "Keep Audible’s AAX filename").SetToolTip(
            "Use the original filename supplied by Audible for a new AAX download when it fits the archive."
        )
        self.text(self.settings, "filename_template", "Filename template").SetToolTip(
            "Use book details and other template tokens in saved filenames."
        )
        self.text(self.settings, "chapter_filename_template", "Chapter filename template").SetToolTip(
            "Name exported chapter files with details such as the chapter number and title."
        )
        self.choice(self.settings, "filename_style", "Name files by",
                    [("unicode", "Title"), ("ascii", "Title (ASCII)"), ("asinUnicode", "ASIN and title"),
                     ("asinASCII", "ASIN and title (ASCII)"), ("asinOnly", "ASIN only")]).SetToolTip(
            "Choose the default filename when the filename template is empty."
        )
        self.number(self.settings, "max_filename_bytes", "Maximum filename length in bytes", 40, 230).SetToolTip(
            "Limit the length of saved file names for compatibility with other devices."
        )
        self.choice(self.settings, "filename_spaces", "Spaces",
                    [("keep", "Keep spaces"), ("hyphen", "Use hyphens"), ("underscore", "Use underscores")]).SetToolTip(
            "Replace spaces in saved filenames with hyphens or underscores if needed."
        )
        self.choice(self.settings, "filename_case", "Letter case",
                    [("original", "Keep original case"), ("lowercase", "Lowercase"), ("uppercase", "Uppercase")]).SetToolTip(
            "Choose how the app capitalizes letters in saved filenames."
        )
        self.check(self.settings, "ascii_names", "Use ASCII characters").SetToolTip(
            "Use basic Latin characters in saved names for compatibility with more devices."
        )
        self.choice(self.settings, "existing_files", "If a file is already saved",
                    [("reuse", "Reuse completed files"), ("new", "Save another copy")]).SetToolTip(
            "Reuse a saved file or create a new copy with a distinct name."
        )

        self.button("Template Preview…", self.preview_files).SetToolTip(
            "Show an example path made from the current folder and filename options."
        )

    def preview_files(self):
        example = {
            "title": "Demo Book", "authors": ["Example Author"], "asin": "B000000001",
            "subtitle": "A Memoir", "narrators": ["Example Narrator"], "series": "Example Series",
            "seriesNumber": "2", "publisher": "Example Press", "year": "2026", "language": "English",
        }
        try:
            layout = ArchiveLayout.from_settings(self.values_for(self.settings))
            profile = ConversionOptions.read(self.preview_conversion())
            chapter = (1, "The Beginning") if profile.chapter_mode == "separate" else ()
            sample = layout.destination(example, profile.format, *chapter)
        except (ValueError, OSError) as error:
            wx.MessageBox(str(error), "Template Preview", wx.OK | wx.ICON_WARNING, self)
            return
        wx.MessageBox(f"{sample}\n\nTokens include {{format}}, {{author}}, {{title}}, {{asin}}, "
                      "{series}, {narrator}, {chapterNumber}, and {chapter}.", "Template Preview", wx.OK, self)

    def jobs(self):
        self.heading("Limits and progress")
        self.number(self.settings, "download_limit", "Simultaneous downloads", 1, 12).SetToolTip(
            "Limit the number of downloads that can run at once."
        )
        self.number(self.settings, "conversion_limit", "Simultaneous conversions", 1, 12).SetToolTip(
            "Limit the number of conversions that can run at once."
        )
        bandwidth = self.number(
            self.settings, "bandwidth", "Bandwidth per download (kbps)", 0, 1000000,
            accessible_label="Bandwidth per download in kilobits per second, 0 for unlimited",
        )
        bandwidth.SetToolTip("Set the bandwidth in kilobits per second for each download. Enter 0 for unlimited.")
        preset_label = wx.StaticText(self, label="Bandwidth preset")
        presets = self.row(preset_label, wx.Choice(self, choices=["Unlimited", "128 kbps", "512 kbps", "1,024 kbps", "4,096 kbps", "Custom"]))
        presets.SetToolTip("Choose a common speed limit or enter a bandwidth limit directly.")
        rates = [0, 128, 512, 1024, 4096]
        presets.SetSelection(rates.index(bandwidth.GetValue()) if bandwidth.GetValue() in rates else 5)
        def preset_changed(event):
            index = presets.GetSelection()
            if index < len(rates):
                bandwidth.SetValue(rates[index])
        presets.Bind(wx.EVT_CHOICE, preset_changed)
        self.number(
            self.settings, "timeout", "Request timeout (seconds)", 0, 600,
            accessible_label="Request timeout in seconds, 0 for unlimited",
        ).SetToolTip("Set the request timeout in seconds. Enter 0 to disable it.")
        self.note("Enter 0 for unlimited bandwidth or timeout.")
        self.daily_download_limit()
        self.check(self.settings, "continue_after_error", "Continue after a job fails").SetToolTip(
            "Start the jobs still waiting in the batch after one job fails."
        )
        self.check(self.settings, "show_progress", "Show detailed transfer progress").SetToolTip(
            "Show progress for each running job and for the batch."
        )
        self.heading("Log")
        self.choice(self.settings, "log_level", "Log",
                    [("off", "Off"), ("errors", "Errors only"), ("all", "Transfer results")]).SetToolTip(
            "Choose whether the transfer log records failures, all results, or nothing."
        )
        log = self.choose_path(self.settings, "log_file", "Log file")
        log.SetToolTip("Choose a file for logging transfer results.")
        self.button("Use Default Location", lambda: log.SetValue("")).SetToolTip(
            "Save the transfer log in DownAudible’s local application data folder."
        )

    def daily_download_limit(self):
        daily = self.settings.get("daily_download_limit")
        if not isinstance(daily, dict):
            daily = {}
        limit = DownloadLimit.read(daily)
        self.heading("Download pacing")
        scope = self.choice(daily, "scope", "Daily download limit", [
            ("off", "Off"), ("plus", "Audible Plus only"), ("all", "All titles"),
        ])
        amount = self.number(daily, "quantity", "Download limit", 1, MAX_LIMIT)
        amount.SetValue(limit.quantity)
        unit = self.choice(daily, "unit", "Unit", [("books", "Books"), ("mb", "MB"), ("gb", "GB")])
        if self.settings.get("daily_download_limit") is not daily:
            self.bindings.append((self.settings, "daily_download_limit", lambda: daily.copy()))
        scope.SetToolTip("Limit new Audible audio over a rolling 24 hours.")
        self.note("Downloads resume automatically as capacity becomes available.")

        def update_controls(_event=None):
            available = scope.GetSelection() > 0
            amount.Enable(available)
            unit.Enable(available)

        scope.Bind(wx.EVT_CHOICE, update_controls)
        update_controls()

    def notifications(self):
        self.heading("Windows Notifications")
        self.button("Open Notification Settings", self.frame.open_notification_settings).SetToolTip(
            "Choose how Windows displays DownAudible notifications."
        )
        self.button("Send Test Notification", lambda: self.frame.notify("This is a test notification.")).SetToolTip(
            "Post a sample notification to check how it appears on this PC."
        )
        self.heading("Transfer Events")
        data = self.settings["notifications"]
        self.feedback_items = {}
        for event, label in FEEDBACK_EVENTS.items():
            entry = dict(data.get(event, {}))
            entry.setdefault("delivery", "off")
            entry.setdefault("sound", "softBell")
            entry.setdefault("custom_sound", self.settings.get("custom_sound", ""))
            self.feedback_items[event] = entry
            choices = [pair for pair in DELIVERIES if pair[0] in {"off", "soundOnly"}] if event == "queueFinished" else DELIVERIES
            self.choice(entry, "delivery", label, choices).SetToolTip(
                f"Choose how DownAudible reports {label.lower()}."
            )
            self.notification_sound(entry, label)

    def notification_sound(self, entry, label):
        sounds = [*self.frame.sounds().items(), ("system", "Windows default"), ("custom", "Custom Sound")]
        custom_index = len(sounds) - 1
        choice = self.choice(entry, "sound", f"{label} sound", sounds)
        choice.SetToolTip("Choose a sound to hear a preview. Select Custom Sound to use an audio file.")
        choose = labeled(wx.Button(self, label="Choose Audio…"), f"Choose a sound for {label}")
        choice.GetContainingSizer().Add(choose, 0, wx.LEFT | wx.ALIGN_CENTER_VERTICAL, self.FromDIP(6))

        def show_path():
            path = entry["custom_sound"]
            name = entry.get("custom_sound_name") or (Path(path).name if path else "")
            choice.SetString(custom_index, f"Custom Sound ({name})" if name else "Custom Sound")
            choose.SetToolTip(f"Selected sound: {name}" if name else "Choose an audio file for this transfer event.")

        def preview(event):
            choose.Show(choice.GetSelection() == custom_index)
            self.Layout()
            self.frame.play_sound(sounds[choice.GetSelection()][0], entry["custom_sound"])

        def browse(event):
            extensions = "*.wav;*.aif;*.aiff;*.m4a;*.mp3;*.aac;*.flac"
            with wx.FileDialog(self, f"Choose Sound for {label}",
                               wildcard=f"Audio files ({extensions})|{extensions}",
                               style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST) as dialog:
                if dialog.ShowModal() != wx.ID_OK:
                    return
                source = Path(dialog.GetPath())
            try:
                sound = import_notification_sound(source, self.frame.data_dir, ffmpeg=self.frame.tools.ffmpeg)
            except (OSError, ValueError) as error:
                wx.MessageBox(str(error), "Sound Could Not Be Imported", wx.OK | wx.ICON_WARNING, self)
                return
            entry["custom_sound"] = str(sound)
            entry["custom_sound_name"] = source.name
            show_path()
            self.frame.play_sound("custom", entry["custom_sound"])

        show_path()
        choose.Show(choice.GetSelection() == custom_index)
        choice.Bind(wx.EVT_CHOICE, preview)
        choose.Bind(wx.EVT_BUTTON, browse)

    def apply(self, vault=None):
        super().apply()
        if self.title == "Library":
            purchase_date_options(self.settings["api"])
        elif self.title == "Conversion":
            ConversionOptions.read(self.settings["conversion"]).validate()
        elif self.title == "Files" and not ArchiveLayout.from_settings(self.settings).is_valid:
            raise ValueError("Check the folder and filename templates before saving.")
        elif self.title == "Notifications":
            for event, preferences in self.feedback_items.items():
                if (preferences["delivery"] in {"soundOnly", "both"} and preferences["sound"] == "custom"
                        and not preferences.get("custom_sound")):
                    raise ValueError(f"Choose a custom audio file for {FEEDBACK_EVENTS[event]} or select another sound.")
            self.settings["notifications"].update(self.feedback_items)
        elif self.title == "Audiobookshelf":
            self.shelf.save(vault)


class SettingsDialog(wx.Dialog):
    def __init__(self, frame, page=None):
        super().__init__(frame, title="DownAudible Settings",
                         style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.frame = frame
        self.notebook = wx.Notebook(self, style=wx.NB_MULTILINE)
        self.pages = [SettingsPage(self.notebook, frame, name, preview_conversion=self.conversion_values)
                      for name in PAGES]
        for name, settings in zip(PAGES, self.pages, strict=True):
            self.notebook.AddPage(settings, name)
        if page in PAGES:
            self.notebook.SetSelection(PAGES.index(page))
        layout = wx.BoxSizer(wx.VERTICAL)
        layout.Add(self.notebook, 1, wx.EXPAND | wx.ALL, self.FromDIP(10))
        layout.Add(self.CreateStdDialogButtonSizer(wx.OK | wx.CANCEL), 0, wx.EXPAND | wx.ALL, self.FromDIP(10))
        self.SetSizer(layout)
        self.Bind(wx.EVT_BUTTON, self.on_apply, id=wx.ID_OK)
        place_dialog(self, frame, (760, 610), (460, 320))

    def conversion_values(self):
        return self.pages[PAGES.index("Conversion")].values_for(self.frame.settings["conversion"])

    def on_apply(self, event):
        try:
            with ExitStack() as vault, save_settings_changes(self.frame):
                for index, page in enumerate(self.pages):
                    try:
                        if page.title == "Audiobookshelf":
                            page.apply(vault)
                        else:
                            page.apply()
                    except (OSError, ValueError):
                        self.notebook.SetSelection(index)
                        raise
        except (OSError, ValueError) as error:
            wx.MessageBox(str(error), "Settings Could Not Be Saved", wx.OK | wx.ICON_ERROR, self)
        else:
            self.EndModal(wx.ID_OK)


class SetupDialog(wx.Dialog):
    def __init__(self, frame, index=-1):
        super().__init__(frame, title="Set Up DownAudible",
                         style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.frame = frame
        self.index = index
        self.history = [-1] if index >= 0 else []
        self.panel = None
        self.intro = None
        self.layout = wx.BoxSizer(wx.VERTICAL)
        self.SetSizer(self.layout)
        self.Bind(wx.EVT_SIZE, self.resize_intro)
        self.Bind(wx.EVT_CHAR_HOOK, self.on_key)
        place_dialog(self, frame, (700, 520), (460, 300))
        self.configure()

    def configure(self):
        self.intro = None
        self.layout.Clear(delete_windows=True)
        if self.index in range(len(PAGES)):
            label = f"{PAGES[self.index]}  (Step {self.index + 1} of {len(PAGES)})"
            body = self.panel = SettingsPage(self, self.frame, PAGES[self.index])
        else:
            label = "Welcome to DownAudible" if self.index < 0 else "You’re Ready to Go"
            self.panel = None
            message = (
                "Connect your Audible account, then choose where to save your books and how to download and convert them.\n\n"
                "You can adjust these choices at any time in Settings."
                if self.index < 0 else "Open DownAudible, or read the guide from Help > DownAudible Help."
            )
            note = wx.StaticText(self, label=message)
            self.intro = (note, message)
            self.wrap_intro()
            body = wx.BoxSizer(wx.VERTICAL)
            body.Add(note, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.TOP, self.FromDIP(8))
        heading = wx.StaticText(self, label=label)
        heading.SetFont(heading.GetFont().Scale(1.4).Bold())
        self.layout.Add(heading, 0, wx.ALL, self.FromDIP(16))
        self.layout.Add(body, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, self.FromDIP(8))
        row = wx.BoxSizer(wx.HORIZONTAL)
        if self.index > -1:
            back = wx.Button(self, label="Back")
            back.Bind(wx.EVT_BUTTON, lambda event: self.move(-1))
            row.Add(back)
        row.AddStretchSpacer()
        secondary = wx.Button(self, label="Skip Setup" if self.index == -1 else
                              "View DownAudible Help" if self.index == len(PAGES) else "Skip Configuration")
        secondary.Bind(wx.EVT_BUTTON, lambda event: self.finish(help_requested=True)
                       if self.index == len(PAGES) else self.move(len(PAGES) - self.index))
        row.Add(secondary, 0, wx.RIGHT, self.FromDIP(8))
        label = "Open DownAudible" if self.index == len(PAGES) else "Continue"
        if self.index == PAGES.index("Accounts") and not self.frame.library.signed_in:
            label = "Continue Without an Account"
        primary = wx.Button(self, label=label)
        primary.SetDefault()
        primary.Bind(wx.EVT_BUTTON, lambda event: self.finish() if self.index == len(PAGES) else self.move(1))
        row.Add(primary)
        self.layout.Add(row, 0, wx.EXPAND | wx.ALL, self.FromDIP(14))
        self.Layout()
        primary.SetFocus()

    def resize_intro(self, event):
        self.wrap_intro()
        event.Skip()

    def on_key(self, event):
        if event.ControlDown() and event.ShiftDown() and not event.AltDown():
            key = event.GetKeyCode()
            if key == ord("B") and self.history:
                self.move(-1)
                return
            if key == ord("P") and self.index < len(PAGES):
                self.move(len(PAGES) - self.index)
                return
            if key == ord("M") and self.index == len(PAGES):
                self.finish(help_requested=True)
                return
        event.Skip()

    def wrap_intro(self):
        if self.intro is not None:
            label, message = self.intro
            width = max(self.FromDIP(32), self.GetClientSize().width - self.FromDIP(32))
            wrap_text(label, message, width)
            self.Layout()

    def move(self, step):
        try:
            with ExitStack() as vault, save_settings_changes(self.frame):
                if self.panel is not None:
                    if self.index == PAGES.index("Audiobookshelf"):
                        self.panel.apply(vault)
                    else:
                        self.panel.apply()
        except (OSError, ValueError) as error:
            wx.MessageBox(str(error), "Check Your Settings", wx.OK | wx.ICON_WARNING, self)
            return
        if step < 0:
            self.index = self.history.pop()
        else:
            self.history.append(self.index)
            self.index += step
        self.configure()

    def finish(self, help_requested=False):
        try:
            with save_settings_changes(self.frame):
                self.frame.settings["setup_complete"] = True
        except (OSError, ValueError) as error:
            wx.MessageBox(str(error), "Setup Could Not Be Saved", wx.OK | wx.ICON_WARNING, self)
        else:
            self.EndModal(wx.ID_HELP if help_requested else wx.ID_OK)

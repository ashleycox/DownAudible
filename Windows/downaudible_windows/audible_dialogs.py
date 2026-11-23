"""Native Windows dialogs for Audible accounts and sign-in."""

from __future__ import annotations

import threading
import uuid
import webbrowser
from io import BytesIO
from itertools import pairwise
from os.path import expanduser
from pathlib import Path

import wx
import wx.adv

from .audible import (
    LEGACY_MARKETPLACES,
    MARKETPLACES,
    AudibleError,
    auth_file_path,
    cli_config_path,
)
from .audible_captcha import captcha_image_data, valid_image_url

NO_ACCOUNTS = "No accounts"
WEB_BROWSER, ENTER_CREDENTIALS, ANDROID_BROWSER = range(3)
SIGN_IN_METHODS = ("Web Browser", "Enter Credentials", "Android Browser (Advanced)")


def button(parent, label, action):
    control = wx.Button(parent, label=label)
    control.Bind(wx.EVT_BUTTON, lambda event: action())
    return control


def shortcuts(window, entries):
    identifiers = [wx.NewIdRef() for _ in entries]
    commands = []
    for identifier, (modifiers, key, action) in zip(identifiers, entries, strict=True):
        commands.append((modifiers, key, int(identifier)))
        window.Bind(wx.EVT_MENU, lambda event, call=action: call(), id=int(identifier))
    window.SetAcceleratorTable(wx.AcceleratorTable(commands))
    return identifiers


def text_field(parent, label, *, value="", style=0):
    field = wx.TextCtrl(parent, value=value, style=style, name=label)
    accessible_name(field, label)
    return field


def accessible_name(control, label):
    if wx.Platform == "__WXMSW__":
        control.SetAccessibleName(label)
        if isinstance(control, wx.SearchCtrl):
            for child in control.GetChildren():
                if isinstance(child, wx.TextCtrl):
                    child.SetAccessibleName(label)


def add_field(sizer, parent, label, control):
    accessible_name(control, label)
    caption = wx.StaticText(parent, label=label)
    sizer.Add(caption, 0, wx.BOTTOM, 4)
    sizer.Add(control, 0, wx.EXPAND | wx.BOTTOM, 10)
    return caption


def show_error(owner, error):
    wx.MessageBox(str(error), "DownAudible", wx.OK | wx.ICON_ERROR, owner)


def finish_dialog(dialog, result):
    if dialog.IsModal():
        dialog.EndModal(result)
    else:
        dialog.Destroy()


def open_browser(url):
    try:
        return webbrowser.open(url)
    except (OSError, webbrowser.Error):
        return False


def challenge_bitmap(data):
    if data is None:
        return None
    quiet = wx.LogNull()
    try:
        image = wx.Image(BytesIO(data))
    finally:
        del quiet
    if not image.IsOk():
        return None
    width, height = image.GetSize()
    scale = min(1, 430 / width, 110 / height)
    if scale < 1:
        image.Rescale(max(1, round(width * scale)), max(1, round(height * scale)), wx.IMAGE_QUALITY_HIGH)
    return image.ConvertToBitmap()


class VerificationDialog(wx.Dialog):
    def __init__(self, parent, kind, image_url, image_data):
        super().__init__(parent, title="Verify Audible Sign-In")
        box = wx.BoxSizer(wx.VERTICAL)
        form = wx.BoxSizer(wx.VERTICAL)
        message, label = {
            "captcha": ("Enter the characters shown in the verification image.", "Verification Characters"),
            "otp": ("Enter your two-step verification code.", "Verification Code"),
            "cvf": ("Enter the verification code sent to your email address or phone.", "Verification Code"),
        }[kind]
        form.Add(wx.StaticText(self, label=message), 0, wx.BOTTOM, 8)
        if kind == "captcha":
            bitmap = challenge_bitmap(image_data)
            if bitmap is not None:
                illustration = wx.StaticBitmap(self, bitmap=bitmap, name="Verification image")
                accessible_name(illustration, "Verification image")
                form.Add(illustration, 0, wx.BOTTOM, 8)
            else:
                form.Add(wx.StaticText(self, label="The verification image could not be loaded."), 0, wx.BOTTOM, 8)
                link = button(self, "Open Verification Image in Browser", lambda: self.show_image(image_url))
                form.Add(link, 0, wx.BOTTOM, 8)
        self.answer = text_field(self, label, style=wx.TE_PASSWORD)
        add_field(form, self, label, self.answer)
        box.Add(form, 0, wx.EXPAND | wx.ALL, 12)
        actions = self.CreateSeparatedButtonSizer(wx.OK | wx.CANCEL)
        submit = self.FindWindowById(wx.ID_OK)
        submit.SetLabel("Continue")
        submit.SetDefault()
        submit.Disable()
        self.answer.Bind(wx.EVT_TEXT, lambda event: submit.Enable(bool(self.answer.GetValue().strip())))
        box.Add(actions, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)
        self.SetSizerAndFit(box)
        self.SetSize((max(440, self.GetSize().width), self.GetSize().height))
        self.answer.SetFocus()

    def show_image(self, url):
        if not open_browser(url):
            wx.MessageBox("The web browser could not open the verification image.",
                          "Verify Audible Sign-In", wx.OK | wx.ICON_ERROR, self)


def run_async(owner, work, success, *, failure=None, done=None, cancel=None):
    """Run helper work off the UI thread and deliver safe results to a live window."""
    def active():
        return bool(owner) and not owner.IsBeingDeleted()

    def deliver(callback, value):
        if not active() or (cancel is not None and cancel.is_set()):
            return
        if done is not None:
            done()
        callback(value)

    def worker():
        try:
            value = work()
        except AudibleError as error:
            if error.code == "cancelled":
                wx.CallAfter(deliver, lambda _value: None, None)
            else:
                wx.CallAfter(deliver, failure or (lambda issue: show_error(owner, issue)), error)
        except OSError:
            wx.CallAfter(deliver, failure or (lambda issue: show_error(owner, issue)), AudibleError("fileAccess"))
        else:
            wx.CallAfter(deliver, success, value)

    threading.Thread(target=worker, daemon=True).start()


class AccountsDialog(wx.Dialog):
    def __init__(self, parent, library):
        super().__init__(parent, title="Accounts", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.library = library
        self.accounts = wx.ListBox(self, name="Audible accounts")
        if wx.Platform == "__WXMSW__":
            self.accounts.SetLabel("Audible accounts")
        self.accounts.Bind(wx.EVT_LISTBOX, lambda event: self.update_actions())
        self.accounts.Bind(wx.EVT_LISTBOX_DCLICK, lambda event: self.switch())
        self.empty_notice = wx.StaticText(self, label=NO_ACCOUNTS)
        panel = wx.BoxSizer(wx.VERTICAL)
        panel.Add(wx.StaticText(self, label="Audible Accounts"), 0, wx.LEFT | wx.RIGHT | wx.TOP, 12)
        panel.Add(self.accounts, 1, wx.EXPAND | wx.ALL, 12)
        empty_section = wx.BoxSizer(wx.VERTICAL)
        empty_section.AddStretchSpacer()
        empty_section.Add(self.empty_notice, 0, wx.ALIGN_CENTER)
        empty_section.AddStretchSpacer()
        self.empty_section = panel.Add(empty_section, 1, wx.EXPAND | wx.ALL, 12)
        first_row = wx.BoxSizer(wx.HORIZONTAL)
        self.add_button = button(self, "Add Account…", self.add)
        self.add_button.SetToolTip("Connect another Audible account by browser or by entering credentials.")
        first_row.Add(self.add_button, 0, wx.RIGHT, 6)
        first_row.Add(button(self, "Import Account…", self.import_account), 0, wx.RIGHT, 6)
        self.widevine_button = button(self, "Widevine Stereo…", self.widevine)
        self.widevine_button.SetToolTip("Review the provider and manage Widevine for this Audible account.")
        first_row.Add(self.widevine_button)
        panel.Add(first_row, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)
        second_row = wx.BoxSizer(wx.HORIZONTAL)
        self.switch_button = button(self, "Switch to This Account", self.switch)
        self.sign_in_button = button(self, "Sign In Again…", self.sign_in)
        self.sign_out_button = button(self, "Sign Out", self.sign_out)
        self.rename_button = button(self, "Rename…", self.rename)
        self.remove_button = button(self, "Remove Account…", self.remove)
        for control in (self.switch_button, self.sign_in_button, self.sign_out_button,
                        self.rename_button, self.remove_button):
            second_row.Add(control, 0, wx.RIGHT, 6)
        self.account_actions = panel.Add(second_row, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)
        android_actions = wx.BoxSizer(wx.HORIZONTAL)
        self.reconnect_android_button = button(self, "Reconnect as Android (Advanced)…",
                                               lambda: self.android_sign_in("reconnect"))
        self.reconnect_android_button.SetToolTip("Sign in again with the same Audible account and keep this profile and its file matches.")
        self.separate_android_button = button(self, "Add Separate Android Profile (Advanced)…",
                                              lambda: self.android_sign_in("separate"))
        self.separate_android_button.SetToolTip("Use the same Audible account in a fresh profile with its own sign-in and file matches.")
        android_actions.Add(self.reconnect_android_button, 0, wx.RIGHT, 6)
        android_actions.Add(self.separate_android_button)
        self.android_actions = panel.Add(android_actions, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)
        self.device_button = button(self, "Deregister This Device…", self.device_registration)
        self.device_button.SetToolTip("Review or deregister the Amazon device saved for this Audible profile.")
        self.device_action = panel.Add(self.device_button, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)
        close = button(self, "Close", self.Close)
        self.SetEscapeId(close.GetId())
        panel.Add(close, 0, wx.ALIGN_RIGHT | wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)
        self.SetSizer(panel)
        self.SetMinSize((645, 330))
        self.SetSize((670, 380))
        shifted = wx.ACCEL_CTRL | wx.ACCEL_SHIFT
        self._shortcuts = shortcuts(self, [
            (shifted, ord("A"), self.add),
            (shifted, ord("I"), self.import_account),
            (shifted, ord("Q"), lambda: self.sign_out() if self.sign_out_button.IsEnabled() else None),
            (shifted, ord("S"), self.activate_selected),
        ])
        self.refresh()
        if self.accounts.IsShown():
            self.accounts.SetFocus()

    def refresh(self, selected=None):
        selected = selected or self.library.active_account_id
        items = self.library.accounts
        self.accounts.Set([self.row_label(item) for item in items])
        index = next((index for index, item in enumerate(items) if item["id"] == selected), wx.NOT_FOUND)
        self.accounts.SetSelection(index)
        self.accounts.Show(bool(items))
        self.empty_section.Show(not items)
        self.account_actions.Show(bool(items))
        self.android_actions.Show(bool(items))
        self.device_action.Show(bool(items))
        self.SetTitle("Accounts" if items else f"Accounts - {NO_ACCOUNTS}")
        self.update_actions()
        self.Layout()
        if not items:
            self.add_button.SetFocus()

    def selected(self):
        index = self.accounts.GetSelection()
        accounts = self.library.accounts
        return accounts[index] if 0 <= index < len(accounts) else None

    def row_label(self, item):
        marketplace = MARKETPLACES.get(item["marketplace"], item["marketplace"])
        state = []
        if item["id"] == self.library.active_account_id:
            state.append("Active")
        if not self.library.is_signed_in(item["id"]):
            state.append("Signed out")
        return " · ".join([f'{item["name"]} ({marketplace})', *state])

    def update_actions(self):
        item = self.selected()
        has_session = bool(item and self.library.is_signed_in(item["id"]))
        can_remove = item is not None and self.library.can_remove_accounts()
        self.switch_button.Enable(bool(item and item["id"] != self.library.active_account_id))
        self.sign_in_button.Enable(item is not None and not has_session)
        self.sign_out_button.Enable(can_remove and has_session)
        self.rename_button.Enable(item is not None)
        self.remove_button.Enable(can_remove)
        self.widevine_button.Enable(has_session and can_remove)
        self.reconnect_android_button.Enable(has_session and can_remove)
        self.separate_android_button.Enable(has_session and can_remove)
        self.device_button.Enable(has_session and can_remove)

    def show_sign_in(self, account=None, *, android_mode=None):
        dialog = SignInDialog(self, self.library, account, android_mode=android_mode)
        try:
            if dialog.ShowModal() == wx.ID_OK:
                self.refresh(dialog.account_id)
        finally:
            dialog.Destroy()

    def add(self):
        self.show_sign_in()

    def sign_in(self):
        if (account := self.selected()) and not self.library.is_signed_in(account["id"]):
            self.show_sign_in(account)

    def android_sign_in(self, mode):
        account = self.selected()
        if account and self.library.is_signed_in(account["id"]) and self.library.can_remove_accounts():
            self.show_sign_in(account, android_mode=mode)

    def device_registration(self):
        if not (account := self.selected()):
            return
        identifier = account["id"]
        try:
            session = self.library.client.session(identifier)
        except AudibleError as error:
            show_error(self, error)
            return

        def show(details):
            try:
                if self.library.client.session(identifier) == session:
                    if not isinstance(details, dict) or details.get("marketplace") != account["marketplace"]:
                        raise AudibleError("accountVerification")
                    with DeviceRegistrationDialog(self, self.library, account, session, details) as dialog:
                        if dialog.ShowModal() == wx.ID_OK:
                            self.refresh(identifier)
            except AudibleError as error:
                show_error(self, error)

        run_async(self, lambda: self.library.client.run("deviceRegistration", session=session), show)

    def rename(self):
        if not (account := self.selected()):
            return
        with wx.TextEntryDialog(self, "Enter the name to show in the account list.", "Rename Account",
                                value=account["name"]) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return
            name = dialog.GetValue().strip()
        if name and name != account["name"]:
            try:
                self.library.rename_account(account["id"], name)
                self.refresh(account["id"])
            except AudibleError as error:
                show_error(self, error)

    def import_account(self):
        dialog = ImportAccountDialog(self, self.library)
        try:
            if dialog.ShowModal() == wx.ID_OK:
                self.refresh(dialog.account_id)
        finally:
            dialog.Destroy()

    def widevine(self):
        if account := self.selected():
            with WidevineDialog(self, self.library, account) as dialog:
                if dialog.ShowModal() == wx.ID_OK:
                    self.refresh(account["id"])

    def switch(self):
        if account := self.selected():
            try:
                self.library.switch_account(account["id"])
                self.refresh(account["id"])
            except AudibleError as error:
                show_error(self, error)

    def activate_selected(self):
        if self.switch_button.IsEnabled():
            self.switch()
        elif self.sign_in_button.IsEnabled():
            self.sign_in()

    def sign_out(self):
        if account := self.selected():
            try:
                self.library.sign_out(account["id"])
                self.refresh(account["id"])
            except AudibleError as error:
                show_error(self, error)

    def remove(self):
        account = self.selected()
        if not account or not self.library.can_remove_accounts():
            return
        confirm = wx.MessageBox(f'Remove {account["name"]}?', "Remove Audible Account",
                                wx.YES_NO | wx.NO_DEFAULT | wx.ICON_QUESTION, self)
        if confirm == wx.YES:
            try:
                self.library.remove_account(account["id"])
                self.refresh()
            except AudibleError as error:
                show_error(self, error)


class DeviceRegistrationDialog(wx.Dialog):
    def __init__(self, parent, library, account, session, registration):
        super().__init__(parent, title="Device Registration")
        self.library, self.account_id, self.session = library, account["id"], session
        self.working = False
        fields = {"android": "Android", "iphone": "iPhone"}
        platform = fields.get(registration.get("kind"), "Unknown")
        region = registration["marketplace"]
        name = registration.get("name") or "Unavailable"
        suffix = registration.get("serialSuffix") or "Unavailable"
        layout = wx.BoxSizer(wx.VERTICAL)
        summary = wx.StaticText(self, label=f'{account["name"]}\nDevice type: {platform}\nDevice name: {name}\n'
                                             f'Marketplace: {MARKETPLACES.get(region, region)}\nSerial ending: {suffix}')
        summary.Wrap(self.FromDIP(400))
        layout.Add(summary, 0, wx.EXPAND | wx.ALL, self.FromDIP(16))
        actions = wx.BoxSizer(wx.HORIZONTAL)
        self.deregister_button = button(self, "Deregister This Device…", self.deregister)
        self.deregister_button.Enable(library.can_remove_accounts())
        actions.Add(self.deregister_button, 0, wx.RIGHT, self.FromDIP(8))
        self.close_button = button(self, "Close", self.Close)
        self.close_button.SetDefault()
        actions.Add(self.close_button)
        self.SetEscapeId(self.close_button.GetId())
        layout.Add(actions, 0, wx.ALIGN_RIGHT | wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(16))
        self.SetSizerAndFit(layout)
        self.Bind(wx.EVT_CLOSE, self.close)
        self.close_button.SetFocus()

    def close(self, event):
        if self.working:
            event.Veto()
        else:
            event.Skip()

    def deregister(self):
        if self.working or not self.library.can_remove_accounts():
            return
        with wx.MessageDialog(
            self, "Amazon will deregister the device used by this profile. Sign in again to request downloads. Saved files stay on this PC.",
            "Deregister This Device", wx.YES_NO | wx.NO_DEFAULT | wx.ICON_WARNING,
        ) as confirmation:
            confirmation.SetYesNoLabels("Deregister Device", "Cancel")
            if confirmation.ShowModal() != wx.ID_YES:
                return
        self.working = True
        self.deregister_button.Disable()
        self.close_button.Disable()

        def work():
            client = self.library.client
            if client.session(self.account_id) != self.session:
                raise AudibleError("accountVerification")
            if client.run("deregisterDevice", session=self.session, confirmed=True) is not True:
                raise AudibleError("deviceDeregistration")

        def finish(_value):
            try:
                if self.library.client.session(self.account_id) == self.session:
                    self.library.sign_out(self.account_id)
            except AudibleError as error:
                show_error(self, error)
                return
            finish_dialog(self, wx.ID_OK)

        def done():
            self.working = False
            self.deregister_button.Enable(self.library.can_remove_accounts())
            self.close_button.Enable()

        run_async(self, work, finish, done=done)


class WidevineDialog(wx.Dialog):
    def __init__(self, parent, library, account):
        super().__init__(parent, title="Widevine Stereo")
        self.library = library
        self.account_id = account["id"]
        self.enabled = account.get("widevine_enabled") is True
        self.working = False
        status = "Enabled" if self.enabled else "Off"
        body = wx.BoxSizer(wx.VERTICAL)
        title = wx.StaticText(self, label=f'{account["name"]} · {status}')
        title.SetFont(title.GetFont().Bold())
        body.Add(title, 0, wx.BOTTOM, self.FromDIP(12))
        for wording in (
            ("Use a compatible Android Audible sign-in to request additional stereo formats with AAX with fallback. "
             "Choose Android Browser (Advanced) when adding an account, or import a compatible Audible CLI sign-in."),
            ("Enabling Widevine sends a signed Audible account-information request, including its ADP "
             "token and signature, to Michael Bucari’s third-party server. The server uses it to "
             "provision a CDM and keeps a hashed account identifier. DownAudible protects the CDM with "
             "your Windows account and reuses it for future downloads."),
        ):
            paragraph = wx.StaticText(self, label=wording)
            paragraph.Wrap(self.FromDIP(470))
            body.Add(paragraph, 0, wx.EXPAND | wx.BOTTOM, self.FromDIP(12))
        for label, url in (
            ("CDM provisioning server", "https://ollj0gz40d.execute-api.us-west-2.amazonaws.com/default/AudibleCdm"),
            ("Michael Bucari’s provisioning documentation",
             "https://github.com/mkb79/audible-cli/issues/155#issuecomment-2788239962"),
            ("pywidevine repository", "https://github.com/devine-dl/pywidevine"),
        ):
            body.Add(wx.adv.HyperlinkCtrl(self, label=label, url=url), 0, wx.BOTTOM, self.FromDIP(6))
        box = wx.BoxSizer(wx.VERTICAL)
        box.Add(body, 0, wx.EXPAND | wx.ALL, self.FromDIP(16))
        actions = self.CreateSeparatedButtonSizer(wx.OK | wx.CANCEL)
        self.action = self.FindWindowById(wx.ID_OK)
        self.cancel = self.FindWindowById(wx.ID_CANCEL)
        self.action_label = "Turn Off Widevine" if self.enabled else "Enable Widevine"
        self.action.SetLabel(self.action_label)
        self.action.Bind(wx.EVT_BUTTON, self.change)
        self.cancel.SetDefault()
        self.Bind(wx.EVT_CLOSE, self.close)
        box.Add(actions, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, self.FromDIP(16))
        self.SetSizerAndFit(box)
        self.cancel.SetFocus()

    def close(self, event):
        if self.working:
            event.Veto()
        else:
            event.Skip()

    def change(self, _event):
        if self.working:
            return

        def apply(cdm):
            try:
                self.library.set_widevine(self.account_id, not self.enabled, cdm)
            except AudibleError as error:
                show_error(self, error)
            else:
                finish_dialog(self, wx.ID_OK)

        if self.enabled:
            apply(None)
            return

        def done():
            self.working = False
            self.cancel.Enable()
            self.action.Enable()
            self.action.SetLabel(self.action_label)

        self.working = True
        self.cancel.Disable()
        self.action.Disable()
        self.action.SetLabel("Preparing…")
        run_async(self, lambda: self.library.client.provision_widevine(self.account_id), apply, done=done)


class SignInDialog(wx.Dialog):
    def __init__(self, parent, library, account=None, *, android_mode=None):
        super().__init__(parent, title="Sign In to Audible", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.library = library
        self.client = library.client
        self.reconnecting = account is not None and android_mode != "separate"
        self.fixed_marketplace = account is not None
        self.android_source_id = account["id"] if android_mode else None
        self.account_id = account["id"] if self.reconnecting else uuid.uuid4().hex
        self.cancel = threading.Event()
        self.browser_attempt = None
        self.working = False
        name = account["name"] if account else ""
        if android_mode == "separate":
            name = f"{name} (Android)"
        self.name = text_field(self, "Account Name", value=name)
        self.marketplace = wx.Choice(self, choices=list(MARKETPLACES.values()), name="Audible marketplace")
        account_market = account["marketplace"] if account else library.sign_in_marketplace
        market = account_market if account_market in MARKETPLACES else "uk"
        self.marketplace.SetSelection(list(MARKETPLACES).index(market))
        self.marketplace.Bind(wx.EVT_CHOICE, self.change_sign_in)
        self.legacy = wx.CheckBox(self, label="Sign in with a legacy Audible username")
        self.legacy.Bind(wx.EVT_CHECKBOX, self.change_sign_in)
        choices = SIGN_IN_METHODS if android_mode or not self.reconnecting else SIGN_IN_METHODS[:ANDROID_BROWSER]
        self.method = wx.Choice(self, choices=choices, name="Sign-in method")
        self.method.SetSelection(ANDROID_BROWSER if android_mode else WEB_BROWSER)
        self.method.Bind(wx.EVT_CHOICE, self.change_sign_in)
        self.user = text_field(self, "Amazon Email Address or Phone Number", style=wx.TE_PROCESS_ENTER)
        self.password = text_field(self, "Password", style=wx.TE_PASSWORD | wx.TE_PROCESS_ENTER)
        self.redirect = text_field(self, "Browser Address", style=wx.TE_PASSWORD | wx.TE_PROCESS_ENTER)
        self.marketplace.SetToolTip("Choose the country or region of your Audible account.")
        self.method.SetToolTip("Choose a browser or credentials. Android browser sign-in prepares a profile for optional Widevine.")
        self.redirect.SetToolTip("Paste the complete address from the last page your browser opens after sign-in.")
        if self.library.frame.demo:
            self.user.SetValue("email@example.com")
            self.password.SetValue("password12345")
        box = wx.BoxSizer(wx.VERTICAL)
        form = wx.BoxSizer(wx.VERTICAL)
        add_field(form, self, "Account" if self.reconnecting else "Account Name (optional)", self.name)
        add_field(form, self, "Marketplace", self.marketplace)
        form.Add(self.legacy, 0, wx.BOTTOM, 12)
        add_field(form, self, "Sign-in Method", self.method)
        android_description = {
            "reconnect": "Sign in with the same Amazon account to keep this profile and its file matches.",
            "separate": "Sign in with the same Amazon account to add a separate DownAudible profile.",
        }.get(android_mode, "Use your existing Amazon account to register an Android sign-in.")
        self.android_notice = wx.StaticText(self, label=f"{android_description}\nEnable Widevine separately in Accounts.")
        form.Add(self.android_notice, 0, wx.EXPAND | wx.BOTTOM, 10)
        self.browser_controls = wx.BoxSizer(wx.VERTICAL)
        instruction = wx.StaticText(
            self,
            label=(
                "A blank page or “Page Not Found” is expected at the end of sign-in.\n"
                "Copy its full address and paste it into Browser Address below."
            ),
        )
        self.browser_controls.Add(instruction, 0, wx.BOTTOM, 8)
        self.open_page = button(self, "Open Sign-In Page", self.open_browser)
        self.restart = button(self, "Start Again", self.reset_browser)
        browser_actions = wx.BoxSizer(wx.HORIZONTAL)
        browser_actions.Add(self.open_page, 0, wx.RIGHT, 6)
        browser_actions.Add(self.restart)
        self.browser_controls.Add(browser_actions, 0, wx.BOTTOM, 8)
        add_field(self.browser_controls, self, "Browser Address", self.redirect)
        form.Add(self.browser_controls, 0, wx.EXPAND)
        self.credentials_controls = wx.BoxSizer(wx.VERTICAL)
        self.user_label = add_field(self.credentials_controls, self, "Amazon Email Address or Phone Number", self.user)
        add_field(self.credentials_controls, self, "Password", self.password)
        form.Add(self.credentials_controls, 0, wx.EXPAND)
        self.status = wx.StaticText(self, label=" ")
        form.Add(self.status, 0, wx.EXPAND | wx.BOTTOM, 6)
        box.Add(form, 1, wx.EXPAND | wx.ALL, 12)
        row = wx.BoxSizer(wx.HORIZONTAL)
        self.submit = button(self, "Sign In", self.sign_in)
        self.submit.SetDefault()
        cancel = button(self, "Cancel", self.Close)
        self.SetEscapeId(cancel.GetId())
        row.Add(cancel, 0, wx.RIGHT, 6)
        row.Add(self.submit)
        box.Add(row, 0, wx.RIGHT | wx.BOTTOM | wx.ALIGN_RIGHT, 12)
        self.SetSizer(box)
        self.SetMinSize((550, 400))
        self.SetSize((590, 440))
        self.Bind(wx.EVT_CLOSE, self.close)
        for control in (self.user, self.password, self.redirect):
            control.Bind(wx.EVT_TEXT, lambda event: self.update_actions())
            control.Bind(wx.EVT_TEXT_ENTER, lambda event: self.sign_in())
        shifted = wx.ACCEL_CTRL | wx.ACCEL_SHIFT
        self._shortcuts = shortcuts(self, [
            (shifted, ord("B"), lambda: self.open_browser() if self.open_page.IsShown() else None),
            (shifted, ord("N"), lambda: self.reset_browser() if self.restart.IsShown() and self.restart.IsEnabled() else None),
        ])
        self.sync_method()

    def get_marketplace(self):
        return list(MARKETPLACES)[self.marketplace.GetSelection()]

    def update_actions(self):
        method = self.method.GetSelection()
        enabled = method != ANDROID_BROWSER and self.get_marketplace() in LEGACY_MARKETPLACES
        self.legacy.Enable(enabled and not self.working)
        self.legacy.Show(enabled)
        if not enabled:
            self.legacy.SetValue(False)
        for control in (self.open_page, self.user, self.password):
            control.Enable(not self.working)
        self.method.Enable(self.android_source_id is None and not self.working)
        self.marketplace.Enable(not self.fixed_marketplace and not self.working)
        self.name.Enable(not self.reconnecting and not self.working)
        caption = "Audible Username" if self.legacy.GetValue() else "Amazon Email Address or Phone Number"
        if self.user_label.GetLabel() != caption:
            self.user_label.SetLabel(caption)
            accessible_name(self.user, caption)
        self.restart.Enable(self.browser_attempt is not None and not self.working)
        self.redirect.Enable(self.browser_attempt is not None and not self.working)
        if method != ENTER_CREDENTIALS:
            ready = self.browser_attempt is not None and self.redirect.GetValue().strip()
        else:
            ready = self.user.GetValue().strip() and self.password.GetValue()
        self.submit.Enable(bool(ready) and not self.working)

    def change_sign_in(self, _event):
        self.reset_browser()
        if not self.library.frame.demo:
            self.password.ChangeValue("")
        self.sync_method()

    def reset_browser(self):
        self.browser_attempt = None
        self.redirect.ChangeValue("")
        self.status.SetLabel(" ")
        self.update_actions()

    def sync_method(self):
        method = self.method.GetSelection()
        browser = method != ENTER_CREDENTIALS
        self.android_notice.Show(method == ANDROID_BROWSER)
        self.browser_controls.ShowItems(browser)
        self.credentials_controls.ShowItems(not browser)
        self.update_actions()
        self.Layout()

    def busy(self, value):
        self.working = value
        self.status.SetLabel("Contacting Audible…" if value else " ")
        self.update_actions()

    def open_browser(self):
        if self.working:
            return
        marketplace = self.get_marketplace()
        android = self.method.GetSelection() == ANDROID_BROWSER
        legacy = not android and self.legacy.GetValue()
        key = (marketplace, legacy, android)

        def opened(attempt):
            self.browser_attempt = (key, attempt)
            self.update_actions()
            self.status.SetLabel(" ")
            if not self.library.frame.demo and not open_browser(attempt["url"]):
                self.offer_to_copy_sign_in_link(attempt["url"])
            self.redirect.SetFocus()

        if self.browser_attempt and self.browser_attempt[0] == key:
            opened(self.browser_attempt[1])
            return

        self.reset_browser()
        self.busy(True)
        fields = {"deviceProfile": "android"} if android else {}
        run_async(self, lambda: self.client.run("beginSignIn", marketplace=marketplace, legacyUsername=legacy,
                                                cancel=self.cancel, **fields),
                  opened, done=lambda: self.busy(False), cancel=self.cancel)

    def offer_to_copy_sign_in_link(self, url):
        self.status.SetLabel("The default web browser could not open.")
        with wx.MessageDialog(
            self, "Copy the sign-in link and paste it into your browser.",
            "Could Not Open Web Browser", wx.YES_NO | wx.NO_DEFAULT | wx.ICON_WARNING,
        ) as dialog:
            dialog.SetYesNoLabels("Copy Sign-In Link", "Cancel")
            if dialog.ShowModal() != wx.ID_YES:
                return
        clipboard = wx.TheClipboard
        copied = False
        if clipboard.Open():
            try:
                copied = clipboard.SetData(wx.TextDataObject(url))
            finally:
                clipboard.Close()
        if copied:
            self.status.SetLabel("Sign-in link copied. Paste it into your browser.")
        else:
            self.status.SetLabel("The sign-in link could not be copied. Try again.")

    def sign_in(self):
        if self.working or not self.submit.IsEnabled():
            return
        marketplace = self.get_marketplace()
        method = self.method.GetSelection()
        android = method == ANDROID_BROWSER
        legacy = not android and self.legacy.GetValue()
        common = {"marketplace": marketplace, "legacyUsername": legacy}
        if method != ENTER_CREDENTIALS:
            address = self.redirect.GetValue().strip()
            attempt = self.browser_attempt
            if not address or not attempt or attempt[0] != (marketplace, legacy, android):
                show_error(self, AudibleError("invalidRedirect"))
                return
            context = attempt[1]
            fields = {"redirect": address, "serial": context["serial"], "verifier": context["verifier"]}
            if android:
                fields.update(deviceProfile="android", registrationContext=context["registrationContext"])
            command = "completeSignIn"
            respond = None
        else:
            fields = {"username": self.user.GetValue().strip(), "password": self.password.GetValue()}
            if not all(fields.values()):
                wx.MessageBox("Enter your Audible sign-in and password.", "Sign In to Audible", wx.OK, self)
                return
            self.password.Clear()
            command = "credentialSignIn"
            respond = self.respond
        self.busy(True)

        def complete():
            previous = None
            if self.android_source_id is not None:
                try:
                    previous = (self.android_source_id, self.client.session(self.android_source_id))
                except AudibleError as error:
                    if error.code == "notSignedIn":
                        raise AudibleError("accountVerification") from None
                    raise
                fields["previousSession"] = previous[1]
            response = self.client.run(command, **common, **fields, respond=respond, cancel=self.cancel)
            return response, previous

        def save(completed):
            self.reset_browser()
            response, previous = completed
            try:
                self.library.save_account(self.account_id, self.name.GetValue().strip(), marketplace, response["session"],
                                          previous_registration=previous)
            except AudibleError as error:
                show_error(self, error)
            else:
                finish_dialog(self, wx.ID_OK)

        def failed(error):
            if command == "completeSignIn" and error.code in {"signInFailed", "accountMismatch", "accountVerification"}:
                self.reset_browser()
            show_error(self, error)

        run_async(self, complete, save, failure=failed, done=lambda: self.busy(False), cancel=self.cancel)

    def respond(self, challenge):
        kind = challenge.get("kind")
        image_url = challenge.get("imageURL")
        image_data = captcha_image_data(image_url, self.cancel) if kind == "captcha" else None
        response = []
        ready = threading.Event()

        def prompt():
            if self.cancel.is_set() or not self:
                ready.set()
                return
            try:
                if kind == "approval":
                    answer = wx.MessageBox("Approve the Audible sign-in request, then choose OK.",
                                           "Approve Sign-In", wx.OK | wx.CANCEL, self)
                    if answer == wx.OK:
                        response.append("")
                    return
                if kind not in {"captcha", "otp", "cvf"} or (kind == "captcha" and not valid_image_url(image_url)):
                    show_error(self, AudibleError("credentialSignInFailed"))
                    return
                with VerificationDialog(self, kind, image_url, image_data) as dialog:
                    if dialog.ShowModal() == wx.ID_OK:
                        response.append(dialog.answer.GetValue().strip())
                    dialog.answer.ChangeValue("")
            finally:
                ready.set()

        wx.CallAfter(prompt)
        while not ready.wait(0.1):
            if self.cancel.is_set():
                return None
        return response[0] if response else None

    def close(self, _event):
        self.cancel.set()
        self.password.ChangeValue("")
        self.redirect.ChangeValue("")
        finish_dialog(self, wx.ID_CANCEL)


class ImportAccountDialog(wx.Dialog):
    CLI_PROFILE, AUTH_FILE, OPEN_AUDIBLE = range(3)

    def __init__(self, parent, library):
        super().__init__(parent, title="Import Account", style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        self.library = library
        self.client = library.client
        self.account_id = uuid.uuid4().hex
        self.cancel = threading.Event()
        self.inspect_cancel = None
        self.inspect_timer = None
        self.inspected_path = None
        self.requires_password = False
        self.importing = False
        self.profiles = []
        self.mode = wx.Choice(self, choices=["CLI Profile", "Auth File", "OpenAudible"], name="Import source")
        self.mode.SetSelection(self.CLI_PROFILE)
        self.mode.Bind(wx.EVT_CHOICE, lambda event: self.sync_mode())
        self.default_path = r"C:\Demo\.audible\config.toml" if library.frame.demo else str(cli_config_path())
        self.path = text_field(self, "Configuration or Auth File", value=self.default_path)
        self.path.Bind(wx.EVT_TEXT, self.path_changed)
        self.profile = wx.Choice(self, name="Profile")
        self.profile.Bind(wx.EVT_CHOICE, lambda event: self.sync_profile())
        self.name = text_field(self, "Account Name")
        self.marketplace = wx.Choice(self, choices=["Use Marketplace in File", *MARKETPLACES.values()], name="Marketplace")
        self.marketplace.SetSelection(0)
        self.password = text_field(self, "Audible CLI Password", style=wx.TE_PASSWORD)
        self.password.Bind(wx.EVT_TEXT, lambda event: self.update_actions())
        box = wx.BoxSizer(wx.VERTICAL)
        form = wx.BoxSizer(wx.VERTICAL)
        add_field(form, self, "Import Source", self.mode)
        self.path_caption = wx.StaticText(self, label="Configuration or Auth File")
        form.Add(self.path_caption, 0, wx.BOTTOM, 4)
        path_row = wx.BoxSizer(wx.HORIZONTAL)
        path_row.Add(self.path, 1, wx.RIGHT, 6)
        self.choose_button = button(self, "Choose…", self.choose)
        path_row.Add(self.choose_button, 0)
        form.Add(path_row, 0, wx.EXPAND | wx.BOTTOM, 10)
        self.profile_row = wx.BoxSizer(wx.VERTICAL)
        add_field(self.profile_row, self, "Profile", self.profile)
        self.load = button(self, "Load Profiles", self.load_profiles)
        self.profile_row.Add(self.load, 0, wx.BOTTOM, 10)
        form.Add(self.profile_row, 0, wx.EXPAND)
        add_field(form, self, "Account Name (optional)", self.name)
        self.marketplace_caption = wx.StaticText(self, label="Marketplace")
        form.Add(self.marketplace_caption, 0, wx.BOTTOM, 4)
        accessible_name(self.marketplace, "Marketplace")
        form.Add(self.marketplace, 0, wx.EXPAND | wx.BOTTOM, 10)
        self.open_audible_marketplace = wx.StaticText(self, label=" ")
        form.Add(self.open_audible_marketplace, 0, wx.BOTTOM, 10)
        self.password_row = wx.BoxSizer(wx.VERTICAL)
        add_field(self.password_row, self, "Audible CLI Password (if encrypted)", self.password)
        form.Add(self.password_row, 0, wx.EXPAND)
        self.status = wx.StaticText(self, label=" ")
        form.Add(self.status, 0, wx.EXPAND | wx.BOTTOM, 6)
        box.Add(form, 1, wx.EXPAND | wx.ALL, 12)
        row = wx.BoxSizer(wx.HORIZONTAL)
        self.submit = button(self, "Import Account", self.import_account)
        self.submit.SetDefault()
        cancel = button(self, "Cancel", self.Close)
        self.SetEscapeId(cancel.GetId())
        row.Add(cancel, 0, wx.RIGHT, 6)
        row.Add(self.submit)
        box.Add(row, 0, wx.RIGHT | wx.BOTTOM | wx.ALIGN_RIGHT, 12)
        self.SetSizer(box)
        self.SetMinSize((550, 430))
        self.SetSize((615, 460))
        tab_order = (self.mode, self.path, self.choose_button, self.profile, self.load,
                     self.name, self.marketplace, self.password, cancel, self.submit)
        for previous, control in pairwise(tab_order):
            control.MoveAfterInTabOrder(previous)
        self.Bind(wx.EVT_CLOSE, self.close)
        self._shortcuts = shortcuts(self, [(wx.ACCEL_CTRL | wx.ACCEL_SHIFT, ord("O"),
                                            lambda: self.choose() if self.choose_button.IsEnabled() else None)])
        self.update_actions()
        if self.library.frame.demo or cli_config_path().is_file():
            self.load_profiles()

    def sync_mode(self):
        source = self.mode.GetSelection()
        self.path.ChangeValue(self.default_path if source == self.CLI_PROFILE else "")
        label = "Credentials File" if source == self.OPEN_AUDIBLE else "Configuration or Auth File"
        self.path_caption.SetLabel(label)
        accessible_name(self.path, label)
        self.invalidate_source()
        self.update_actions()
        if source == self.CLI_PROFILE and (self.library.frame.demo or cli_config_path().is_file()):
            self.load_profiles()

    def choose(self):
        source = self.mode.GetSelection()
        title, wildcard = {
            self.CLI_PROFILE: ("Choose Audible CLI Configuration", "TOML files (*.toml)|*.toml|All files (*.*)|*.*"),
            self.AUTH_FILE: ("Choose Auth File", "All files (*.*)|*.*"),
            self.OPEN_AUDIBLE: ("Choose OpenAudible Credentials", "JSON files (*.json)|*.json|All files (*.*)|*.*"),
        }[source]
        with wx.FileDialog(self, title, wildcard=wildcard, style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST) as dialog:
            if dialog.ShowModal() == wx.ID_OK:
                self.path.ChangeValue(dialog.GetPath())
                self.load_profiles()

    def invalidate_source(self):
        if self.inspect_timer is not None:
            self.inspect_timer.Stop()
            self.inspect_timer = None
        if self.inspect_cancel is not None:
            self.inspect_cancel.set()
            self.inspect_cancel = None
        self.inspected_path = None
        self.profiles = []
        self.profile.Clear()
        self.name.ChangeValue("")
        self.marketplace.SetSelection(0)
        self.open_audible_marketplace.SetLabel(" ")
        self.password.ChangeValue("")
        self.requires_password = False
        self.status.SetLabel(" ")
        self.update_actions()

    def path_changed(self, _event):
        self.invalidate_source()
        if self.path.GetValue().strip():
            self.inspect_timer = wx.CallLater(250, self.load_profiles)

    def load_profiles(self):
        path = self.path.GetValue().strip()
        if not path:
            return
        self.invalidate_source()
        reading = self.inspect_cancel = threading.Event()
        source = self.mode.GetSelection()
        command = {self.CLI_PROFILE: "cliProfiles", self.AUTH_FILE: "inspectAuthFile",
                   self.OPEN_AUDIBLE: "inspectOpenAudible"}[source]

        def loaded(result):
            if self.inspect_cancel is not reading or self.path.GetValue().strip() != path:
                return
            self.inspect_cancel = None
            self.inspected_path = path
            self.status.SetLabel(" ")
            if source != self.AUTH_FILE:
                self.profiles = result
                if source == self.OPEN_AUDIBLE:
                    self.profile.Set([f'{item["name"]} ({MARKETPLACES[item["marketplace"]]})' for item in result])
                else:
                    self.profile.Set([item["name"] + (" (Default)" if item.get("isDefault") else "") for item in result])
                if self.profiles:
                    primary = next((index for index, item in enumerate(result) if item.get("isDefault")), 0)
                    self.profile.SetSelection(primary)
                    self.sync_profile()
            else:
                self.name.ChangeValue(Path(path).stem)
                self.requires_password = result
            self.update_actions()

        def failed(error):
            if self.inspect_cancel is reading:
                self.inspect_cancel = None
                self.status.SetLabel(str(error))
                self.update_actions()

        self.status.SetLabel("Reading account file…")
        self.update_actions()
        run_async(self, lambda: self.client.run(command, file=expanduser(path), cancel=reading),
                  loaded, failure=failed, cancel=reading)

    def sync_profile(self):
        index = self.profile.GetSelection()
        if not 0 <= index < len(self.profiles):
            return
        item = self.profiles[index]
        self.name.ChangeValue(item["name"])
        marketplace = item.get("marketplace")
        self.marketplace.SetSelection(list(MARKETPLACES).index(marketplace) + 1 if marketplace in MARKETPLACES else 0)
        self.open_audible_marketplace.SetLabel(MARKETPLACES.get(marketplace, " "))
        self.requires_password = item.get("requiresPassword", False)
        self.password.ChangeValue("password12345" if self.library.frame.demo and self.requires_password else "")
        self.update_actions()

    def update_actions(self):
        source = self.mode.GetSelection()
        has_file = self.inspected_path is not None and self.inspected_path == self.path.GetValue().strip()
        ready = has_file and (source == self.AUTH_FILE or 0 <= self.profile.GetSelection() < len(self.profiles))
        self.profile_row.ShowItems(source != self.AUTH_FILE)
        self.marketplace.Show(source != self.OPEN_AUDIBLE)
        self.marketplace_caption.Show(source != self.OPEN_AUDIBLE or ready)
        self.open_audible_marketplace.Show(source == self.OPEN_AUDIBLE and ready)
        self.load.Enable(not self.importing and bool(self.path.GetValue().strip()) and self.inspect_cancel is None)
        for control in (self.mode, self.path, self.choose_button):
            control.Enable(not self.importing)
        self.profile.Enable(not self.importing and bool(self.profiles))
        for control in (self.name, self.marketplace, self.password):
            control.Enable(not self.importing and ready)
        self.password_row.ShowItems(self.requires_password)
        self.submit.Enable(not self.importing and ready and (not self.requires_password or bool(self.password.GetValue())))
        self.Layout()

    def import_account(self):
        if not self.submit.IsEnabled():
            return
        source = self.mode.GetSelection()
        path = expanduser(self.inspected_path)
        fields = {}
        selected_marketplace = None
        if source == self.CLI_PROFILE:
            index = self.profile.GetSelection()
            try:
                path = str(auth_file_path(self.profiles[index]["authFile"]))
            except (KeyError, TypeError, ValueError, AudibleError):
                show_error(self, AudibleError("authImport"))
                return
        if source == self.OPEN_AUDIBLE:
            marked = self.profiles[self.profile.GetSelection()]
            selected_marketplace = marked["marketplace"]
            fields["checkpoint"] = marked["checkpoint"]
            command = "importOpenAudible"
        else:
            selection = self.marketplace.GetSelection()
            fields["marketplace"] = list(MARKETPLACES)[selection - 1] if selection > 0 else None
            fields["password"] = self.password.GetValue() or None
            command = "importAuthFile"
        name = self.name.GetValue().strip()
        self.password.ChangeValue("")
        self.importing = True
        self.status.SetLabel("Importing Audible account…")
        self.update_actions()

        def done():
            self.importing = False
            self.status.SetLabel(" ")
            self.update_actions()

        def save(response):
            try:
                if selected_marketplace is not None and response["marketplace"] != selected_marketplace:
                    raise AudibleError("accountMismatch")
                self.library.save_account(self.account_id, name, response["marketplace"], response["session"])
            except AudibleError as error:
                show_error(self, error)
            else:
                finish_dialog(self, wx.ID_OK)

        def failed(error):
            show_error(self, error)

        run_async(self, lambda: self.client.run(command, file=path, cancel=self.cancel, **fields),
                  save, failure=failed, done=done, cancel=self.cancel)

    def close(self, _event):
        self.cancel.set()
        self.invalidate_source()
        finish_dialog(self, wx.ID_CANCEL)

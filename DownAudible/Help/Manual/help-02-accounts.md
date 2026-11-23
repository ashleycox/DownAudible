# Accounts and Sign-In

## Choose a sign-in method

On the Accounts page in setup or in **Settings > Accounts**, click **Add Account…**. Choose your Audible marketplace. If you use separate accounts, give this one a name you will recognise in the account menu.

If you use an Audible username, turn on **Sign in with a legacy Audible username**. This option is available for the UK, US, and German marketplaces.

![Audible sign-in sheet highlighting the marketplace, legacy username checkbox, and method set to Web Browser.](images/sign-in-methods.png)

## Sign in with your browser

Choose **Web Browser** in **Sign-in method**, then click **Continue** and **Open Sign-In Page**. Complete the sign-in in your browser, including any verification it asks for.

A blank page or a “Page Not Found” message at the end is expected. Copy the full address of that page from your browser’s address bar, paste it into **Browser address** in DownAudible, then click **Sign In**.

![Browser sign-in sheet with Open Sign-In Page and the Browser address field.](images/sign-in-browser.png)

## Connect an Android sign-in

Choose **Android Browser (Advanced)** under **Add Account…** to connect your Audible account using a registration that supports Widevine. To work with a saved account, select it in **Settings > Accounts** and choose **Reconnect as Android (Advanced)…** to keep the profile or **Add Separate Android Profile (Advanced)…** to keep both registrations. See [Widevine Stereo](help-13-widevine.md#connect-a-compatible-android-sign-in) for both workflows.

## Enter your credentials in DownAudible

Choose **Enter Credentials** in **Sign-in method**. Enter your Amazon email address or phone number and password, then click **Sign In**. If you turned on legacy username sign-in, enter your Audible username and password.

![Direct sign-in sheet with email@example.com and a masked example password.](images/sign-in-credentials.png)

Follow any verification prompts that appear. If Amazon asks you to approve the sign-in in a notification, approve it before you click **Continue**. If you need another verification method, use **Web Browser**. DownAudible saves the resulting sign-in session in your Mac’s Keychain and discards the password.

## Import an account

Click **Import Account…** on the Accounts page in setup or in **Settings > Accounts**. Choose **CLI profile** to read profiles from the CLI’s configuration file. DownAudible looks for `config.toml` in the CLI’s configured directory, usually `~/.audible`. Click **Choose…** if your configuration is stored elsewhere.

![Audible CLI import sheet with CLI profile selected and Demo Account in the profile menu.](images/sign-in-cli.png)

Choose **Auth file** to open an authentication file directly. Enter its Audible CLI password if it is encrypted. You can give the account a different display name and pick the marketplace if the file needs one. DownAudible saves the imported session in your Mac’s Keychain.

![Audible CLI import sheet with Auth file selected and controls for the file and password.](images/sign-in-cli-auth.png)

## Import from OpenAudible

Click **Import Account…**, choose **OpenAudible**, then click **Choose…** to open the `credentials.json` file saved by OpenAudible. Select the **Profile** you want to use and check its marketplace. You can change the name shown in DownAudible before clicking **Import**.

![Import Account sheet with OpenAudible selected, a sample credentials.json file, and the Demo Account profile for the United Kingdom.](images/import-openaudible.png)

DownAudible verifies the saved sign-in with Audible, then stores it in Keychain. Repeat these steps to import another profile from the file. If Audible rejects a sign-in, reconnect that account in OpenAudible and choose its current file.

The apps share the imported device registration. **Deregister This Device…** in DownAudible also revokes that registration for OpenAudible. Use **Match Existing Folder…** to connect audio you saved in OpenAudible. [Library and file matching](help-03-library.md)

## Use Widevine stereo

Widevine is off by default. With a compatible Android registration, choose **Widevine Stereo…** for the account to review the provider and decide whether to enable it. See [Widevine Stereo](help-13-widevine.md) for when it helps, what DownAudible shares, and which download format to choose.

## Switch or remove an account

Use the account menu in the Library toolbar, or select an account in **Settings > Accounts** and click **Switch to This Account**. The library and file matches change with the account. A running batch uses the account it started with.

To revoke this app’s saved Audible device registration, select the signed-in profile in **Settings > Accounts** and choose **Deregister This Device…**. Check the profile and device details, then confirm **Deregister**. The profile signs out. Your saved books, file matches and transfers stay on the Mac. Use Amazon’s **Manage Your Content and Devices** page to review older devices whose sign-ins you no longer have in DownAudible.

![Audible Device Registration showing Demo Account, the device name, the end of the device serial, and the deregistration button.](images/audible-device-registration.png)

![Demo Account 2 selected in Accounts settings with the Switch to This Account button.](images/settings-accounts-switch.png)

**Sign Out** clears the saved session, so you can sign in to that profile again later. **Remove Account…** also removes the profile and its file matches. Use **Rename…** to change the name shown in the account menu.

![Accounts settings with Demo Account selected and buttons to reconnect as Android or add a separate Android profile.](images/settings-accounts.png)

## Related chapters

[Audible Tools](help-08-audible-tools.md)

[Troubleshooting](help-09-troubleshooting.md)

## Keyboard Shortcuts

| Command | Shortcut |
| --- | --- |
| Sign In… / Add Account… in Library | Control–Shift–A |
| Sign In… / Switch to This Account in Settings or setup | Control–Shift–S |
| Import Account… | Control–Shift–I |
| Open Sign-In Page | Control–Shift–B |
| Continue or Sign In in the sign-in sheet | Return |
| Sign Out | Control–Shift–Q |

[See all keyboard shortcuts](help-10-keyboard-shortcuts.md)

---

## Support DownAudible

If you like DownAudible, a donation is one way to support my work. There’s no pressure or hard sell. DownAudible is and always will be free.

[Make a donation](https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE)

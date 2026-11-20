# DownAudible

<img src="AppAssets/DownAudible.png" alt="DownAudible icon showing a mint-green arrow pointing into an open book" width="96" height="96" align="right">

DownAudible backs up your Audible library on a Mac. Keep the original DRM-protected Audible files, which can still be played in Apple's Books app, or convert them to M4B, M4A, or MP3 and play them on any device, with support for embedded and split chapters and embedded cover art.

## Why I built DownAudible

I built DownAudible one morning after discovering Audible had removed the download button from their website, removing access to the books we bought and paid for. I have been an Audible user for years and have amassed a library of thousands of books.

I refuse to use the Audible app. It is an atrocity, especially on macOS. We must all fight against our right to ownership being stripped from us. I have spent thousands of pounds over many years building a library of books, and I will do with them as I please within the remit of legal personal use. If you pay for something without the explicit knowledge that you are renting it, you should own access to it, even if the product is digital.

## Download

[**Download DownAudible for Mac (.zip)**](https://github.com/ashleycox/DownAudible/releases/latest/download/DownAudible.zip)

DownAudible runs on Apple silicon and Intel Macs with macOS 15 or later. Unzip the download and drag DownAudible to your Applications folder.

Choose **DownAudible → Check for Updates…** to check for a new release. Enable automatic updates in **Settings → General** or on the General page during setup.

## Getting Started

The setup wizard opens the first time you run DownAudible. Use it to connect an account, choose the destination, and set your download and conversion defaults. On the Accounts page, choose **Continue Without an Account** to work with local files. **Help → Set Up DownAudible…** opens setup again with your saved settings.

1. On the Accounts page in setup or in **Settings → Accounts**, click **Add Account…**. Sign in through your browser, then paste the resulting address into DownAudible. You can also choose **Import from Audible CLI…**.
2. If you already have files, use **Match Existing Folder…** to scan your archive or a folder from another app. You can fix an individual match from its contextual menu.
3. In **Audiobooks → Download**, choose **Download Missing** to fetch eligible titles without a complete audio copy, or select books and choose **Download Selected**. Use the corresponding **As…** command to review the destination, audio, conversion, and optional PDFs, cover images, chapters, and notes.
4. If a batch is interrupted, open **Downloads** and choose **Retry Incomplete**. Choose **Restart Download…** from a job’s contextual menu to download it again from the beginning.

In **Settings → Notifications**, choose sounds and alerts, check macOS permissions, or send a silent test. Click a transfer alert to open its jobs in **Downloads**.

**Audiobooks → Audible Tools** opens the wish list, catalogue search, activation bytes, and encrypted Audible CLI account export for the current account. Use **Audiobooks → Library → Export Library** to save the loaded library as JSON, CSV, or TSV.

Use **Sort Library** and **Filter Library** in the library toolbar or the **View** menu to organise the table. Each account remembers its sort order. Filters clear when you switch accounts or quit. **Settings → Library** controls suggestions as you type a filter. **View → Library Status** shows which books need audio, which are downloaded or matched, and which Audible lists as unavailable. The **View** menu also controls the sidebar and the library status bar.

## Conversion and file names

To convert existing files, drag them into **Convert Files** or choose **Add Files** or **Add Folder**. **Audiobooks → Conversion Options…** controls the format, chapters, audio encoding, artwork, and metadata. In **Settings → Downloads**, you can send new original downloads or M4Bs to Apple Books.

When creating separate M4B or M4A files, turn on **Copy chapter audio when possible** to keep the original audio for compatible AAC chapters.

When exporting MP3, turn on **Move converted AAX files to Trash** to remove eligible AAX sources after the complete export is saved.

If an AAX download can’t be converted, try **AAX with fallback** in **Settings → Downloads**. AAX files opened in **Convert Files** need the activation code for the account that downloaded them.

Folder and filename templates are independent. The default folder template, `{format}/{author}/{title}`, groups original and converted formats separately. For chapter filenames you might use `{title} - {chapterNumber} - {chapter}`. Settings shows a preview as you edit.

Turn on **Keep Audible’s AAX filename** in **Settings → Files** to save new AAX downloads under the name Audible supplies when available.

## Manual and keyboard shortcuts

Open **Help → DownAudible Help** for the manual or choose **Settings Reference** or **Keyboard Shortcuts** to go straight to that chapter. **Settings → General → Show Help Tags** controls the tips shown when you point to DownAudible controls. [Manual contents](DownAudible/Help/Manual/README.md) · [Settings reference](DownAudible/Help/Manual/help-12-settings.md) · [Keyboard shortcuts](DownAudible/Help/Manual/help-10-keyboard-shortcuts.md)

## Build and run

You’ll need an Apple silicon Mac with Xcode 27.2, uv, and Rosetta. [Xcode](https://developer.apple.com/xcode/) · [Install uv](https://docs.astral.sh/uv/getting-started/installation/) · [Install Rosetta](https://support.apple.com/en-gb/102527)

Open `DownAudible.xcodeproj`, select the **DownAudible** scheme, and press Command-R. To build and run from Terminal, use these commands.

```sh
xcodebuild -scheme DownAudible \
  -configuration Debug \
  -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/DownAudible.app
```

## Credits

DownAudible is developed by [Ashley Cox](https://ashleycox.co.uk). The source is licensed under the GNU Affero General Public License, version 3. [Licence](LICENSE)

[Credits and licences](DownAudible/Help/Manual/help-11-credits.md)

## Support DownAudible

If this app has helped you and you’d like to support my work, you can [make a donation](https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE). There’s no pressure or hard sell. DownAudible is and always will be free.

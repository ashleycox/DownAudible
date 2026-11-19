# DownAudible

<img src="AppAssets/DownAudible.png" alt="DownAudible icon showing a mint-green arrow pointing into an open book" width="96" height="96" align="right">

DownAudible backs up your Audible library on a Mac. Keep the original DRM-protected Audible files, or convert them to M4B, M4A, or MP3 and play them on any device, with support for embedded and split chapters and embedded cover art.

## Why I built DownAudible

I built DownAudible one morning after discovering Audible had removed the download button from their website, removing access to the books we bought and paid for. I have been an Audible user for years and have amassed a library of thousands of books.

I refuse to use the Audible app. It is an atrocity, especially on macOS. We must all fight against our right to ownership being stripped from us. I have spent thousands of pounds over many years building a library of books, and I will do with them as I please within the remit of legal personal use. If you pay for something without the explicit knowledge that you are renting it, you should own access to it, even if the product is digital.

## Download

[**Download DownAudible for Mac (.zip)**](https://github.com/ashleycox/DownAudible/releases/latest/download/DownAudible.zip)

DownAudible requires an Apple silicon Mac running macOS 15 or later. Unzip the download and drag DownAudible to Applications.

## Start with your library

Setup opens the first time you run DownAudible. Use it to connect an account, choose the destination, and set your download and conversion defaults. On the Accounts page, choose **Continue Without an Account** to work with local files. **Help → Set Up DownAudible…** opens setup again with your saved settings.

1. On the Accounts page in setup or in **Settings → Accounts**, click **Add Account…**. Sign in through your browser, then paste the resulting address into DownAudible. You can also choose **Import from Audible CLI…**. Each account has a separate session in Keychain.
2. If you already have files, use **Match Existing Folder…** to scan your archive or a folder from another app. You can fix an individual match from its contextual menu.
3. In **Audiobooks → Download**, choose **Download Missing** to fetch eligible titles without a complete audio copy, or select books and choose **Download Selected**. Use the corresponding **As…** command to review the destination, audio, conversion, and optional PDFs, cover images, chapters, and notes.
4. If a batch is interrupted, open **Downloads** and choose **Retry Incomplete**. DownAudible resumes partial audio when Audible can confirm it is the same file. Choose **Restart Download…** from a job’s contextual menu to discard its temporary bytes and download it from the start.

**Audiobooks → Audible Tools** opens the wish list, catalogue search, activation bytes, and encrypted Audible CLI account export for the current account. Use **Audiobooks → Library → Export Library** to save the loaded library as JSON, CSV, or TSV.

**View → Library Status** shows which books need audio, which are downloaded or matched, and which Audible lists as unavailable. The **View** menu also controls the sidebar and the library status bar.

## Conversion and file names

To convert existing files, drag them into **Convert Files** or choose **Add Files** or **Add Folder**. **Audiobooks → Conversion Options…** controls the format, chapters, audio encoding, artwork, and metadata. In **Settings → Downloads**, you can send new original downloads or M4Bs to Apple Books.

Folder and filename templates are independent. The default folder template, `{format}/{author}/{title}`, groups original and converted formats separately. For chapter filenames you might use `{title} - {chapterNumber} - {chapter}`. Settings shows a preview as you edit.

Turn on **Keep Audible’s AAX filename** in **Settings → Files** to save new AAX downloads under the name Audible supplies when available.

## Manual and keyboard shortcuts

Open **Help → DownAudible Help** for the manual, including steps for recovering a batch, fixing missing files, and using Audible CLI profiles. **Help → Keyboard Shortcuts** opens the keyboard reference. [Browse manual chapters](DownAudible/Help/Manual) · [Keyboard shortcuts](DownAudible/Help/Manual/help-10-keyboard-shortcuts.md)

From an Applications folder, these commands open macOS Help. From a build folder, DownAudible displays the same help pages in its own windows.

## Build and run

If you wish to build from source, you’ll need an Apple silicon Mac, Xcode 27.2, and uv. DownAudible targets macOS 15 and later. The first build downloads the Audible helper’s dependencies and compiles FFmpeg and LAME. Later builds reuse the tools. [Xcode](https://developer.apple.com/xcode/) · [Install uv](https://docs.astral.sh/uv/getting-started/installation/)

Open `DownAudible.xcodeproj`, choose the **DownAudible** scheme, and choose product>run or press Command-R. To build from Terminal, run

```sh
xcodebuild -scheme DownAudible \
  -configuration Debug \
  -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/DownAudible.app
```

Automatic signing is enabled. The checked-in settings sign builds to run locally. To use your Apple development team, sign in under **Xcode > Settings > Accounts**, then create `Signing.local.xcconfig` beside `App.xcconfig` with your Team ID.

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_IDENTITY = Apple Development
```

Git ignores this file. Set the team here so Xcode leaves the shared project file free of team-specific settings. Xcode uses the signing identities in your Keychain or Apple’s signing service.

## Checks

Run the archive checks and the Audible helper’s mocked network tests without signing in.

```sh
Scripts/check-archive.sh
PYTHONPATH=Scripts/Audible \
  UV_PROJECT_ENVIRONMENT=.build/audible-tests \
  uv run --project Scripts/Audible \
  --locked --python 3.13 \
  python -m unittest discover \
  -s Scripts/Audible/tests
```

## Credits

DownAudible is developed by [Ashley Cox](https://ashleycox.co.uk). The source is licensed under the GNU Affero General Public License, version 3. [Licence](LICENSE)

The Audible helper uses mkb79’s Audible and Audible CLI libraries. Libation and AAX Audio Converter were references for the download and conversion workflow. [Audible](https://github.com/mkb79/Audible) · [Audible CLI](https://github.com/mkb79/audible-cli) · [Libation](https://github.com/rmcrackan/Libation) · [AAX Audio Converter](https://github.com/audiamus/AaxAudioConverter)

The build script pins and builds the bundled FFmpeg and LAME sources. [FFmpeg](https://ffmpeg.org/) · [LAME](https://lame.sourceforge.io/) · [Build script](Scripts/prepare-media.sh)

[Credits and licences](DownAudible/Help/Manual/help-11-credits.md)

## Support DownAudible

If this app has helped you and you’d like to support my work, you can [make a donation](https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE). There’s no pressure or hard sell. DownAudible is and always will be free.

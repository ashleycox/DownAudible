# DownAudible

DownAudible backs up your Audible library on a Mac. Keep the original downloads, or convert them to M4B, M4A, or MP3. You can keep a book in one file or save each chapter separately.

## Build and run

You’ll need an Apple silicon Mac, Xcode 27.2, and uv. DownAudible targets macOS 15 and later. The first build downloads the Audible helper’s dependencies and compiles FFmpeg and LAME. Later builds reuse the tools. [Xcode](https://developer.apple.com/xcode/) · [Install uv](https://docs.astral.sh/uv/getting-started/installation/)

Open `DownAudible.xcodeproj`, choose the **DownAudible** scheme, and press Command-R. To build from Terminal, run

```sh
xcodebuild -scheme DownAudible -configuration Debug -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/DownAudible.app
```

Automatic signing is enabled. The checked-in settings sign builds to run locally. To use your Apple development team, put `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY = Apple Development` in `Signing.local.xcconfig` beside `App.xcconfig`. Git ignores the local file.

## Start with your library

Setup opens the first time you run DownAudible. Use it to connect an account, choose the destination, and set your download and conversion defaults. On the Accounts page, choose **Continue Without an Account** to work with local files. **Help → Set Up DownAudible…** opens setup again with your saved settings.

1. On the Accounts page in setup or in **Settings → Accounts**, click **Add Account…**. Sign in through your browser, then paste the resulting address into DownAudible. You can also choose **Import from Audible CLI…**. Each account has a separate session in Keychain.
2. If you already have files, use **Match Existing Folder**. You can fix an individual match from its contextual menu.
3. Choose **Download Missing** to fetch eligible titles without a complete audio copy, or select books and choose **Download Selected**. Use the corresponding **As…** command to review the destination, audio, conversion, and optional PDFs, cover images, chapters, and notes.
4. If a batch is interrupted, open **Transfers** and choose **Retry Incomplete**. DownAudible resumes partial audio when Audible can confirm it is the same file. Choose **Restart Download…** from a transfer’s contextual menu to discard its temporary bytes and download it from the start.

**Audiobooks → Audible Tools** opens the wish list, catalogue search, activation bytes, and encrypted Audible CLI account export for the current account. Use **Export Library** to save the displayed library as JSON, CSV, or TSV.

**View → Library Status** shows which books need audio, which are downloaded or matched, and which Audible lists as unavailable. The **View** menu also controls the sidebar and the library status bar. Open **Help → Keyboard Shortcuts** for the keyboard reference.

## Conversion and file names

To convert existing files, drag them into **Convert Files** or choose **Add Files** or **Add Folder**. **Conversion Options** controls the format, chapters, audio encoding, artwork, and metadata. In **Settings → Downloads**, you can send new original downloads or M4Bs to Apple Books.

Folder and filename templates are independent. The default folder template, `{format}/{author}/{title}`, groups original and converted formats separately. For chapter filenames you might use `{title} - {chapterNumber} - {chapter}`. Settings shows a preview as you edit.

Open **Help → DownAudible Help** for the chapterised manual, including steps for recovering a batch, fixing missing files, and using Audible CLI profiles. [Browse manual chapters](DownAudible/Help/Manual)

## Checks

Run the archive checks and the Audible helper’s mocked network tests without signing in.

```sh
Scripts/check-archive.sh
PYTHONPATH=Scripts/Audible UV_PROJECT_ENVIRONMENT=.build/audible-tests \
  uv run --project Scripts/Audible --locked --python 3.13 python -m unittest discover -s Scripts/Audible/tests
```

## Credits

Ashley Cox develops DownAudible. The source is licensed under the GNU Affero General Public License, version 3. [Ashley Cox](https://ashleycox.co.uk/) · [Licence](LICENSE)

The Audible helper uses mkb79’s Audible library and draws on Audible CLI. Libation and AAX Audio Converter were references for the download and conversion workflow. [Audible](https://github.com/mkb79/Audible) · [Audible CLI](https://github.com/mkb79/audible-cli) · [Libation](https://github.com/rmcrackan/Libation) · [AAX Audio Converter](https://github.com/audiamus/AaxAudioConverter)

The build script pins and builds the bundled FFmpeg and LAME sources. [FFmpeg](https://ffmpeg.org/) · [LAME](https://lame.sourceforge.io/) · [Build script](Scripts/prepare-media.sh)

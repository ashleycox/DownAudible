# DownAudible

<img src="AppAssets/DownAudible.png" alt="DownAudible icon showing a mint-green arrow pointing into an open book" width="96" height="96" align="right">

DownAudible backs up your Audible library on a Mac. Keep the original DRM-protected Audible files, which can still be played in Apple's Books app, or convert them to M4B, M4A, or MP3 and play them on any device, with support for embedded and split chapters and embedded cover art.

## Why I built DownAudible

I built DownAudible one morning after discovering Audible had removed the download button from their website, removing access to the books we bought and paid for. I have been an Audible user for years and have amassed a library of thousands of books.

I refuse to use the Audible app. It is an atrocity, especially on macOS. We must all fight against our right to ownership being stripped from us. I have spent thousands of pounds over many years building a library of books, and I will do with them as I please within the remit of legal personal use. If you pay for something without the explicit knowledge that you are renting it, you should own access to it, even if the product is digital.

## Download

[**Download DownAudible for Mac (.zip)**](https://github.com/ashleycox/DownAudible/releases/latest/download/DownAudible.zip)

DownAudible runs on Apple silicon and Intel Macs, running MacOS 15 Catalina or later. Unzip the download and drag DownAudible to your Applications folder.

Choose **DownAudible → Check for Updates…** to check for a new release. Enable automatic updates in **Settings → General** or on the General page during setup.

## Manual and keyboard shortcuts

Start with the [DownAudible manual](DownAudible/Help/Manual/README.md).

Open **Help → DownAudible Help** for the manual or choose **Settings Reference** or **Keyboard Shortcuts** to go straight to that chapter. **Settings → General → Show Help Tags** controls the tips shown when you point to DownAudible controls. [Settings reference](DownAudible/Help/Manual/help-12-settings.md) · [Keyboard shortcuts](DownAudible/Help/Manual/help-10-keyboard-shortcuts.md)

## Features

### Library and accounts

- Multiple Audible accounts and marketplaces
- Audible CLI account import and password-protected account export
- Look up and copy Audible activation bytes
- Library search, sorting and filters
- Automatic and manual matching for audio files you already have
- Library and wish list export as JSON, CSV or TSV
- Audible catalogue search and wish list management

### Downloads

- Download selected books, missing books or the entire library
- Save original AAX or AAXC files
- Request whole-book downloads first, with a fallback to individual parts
- Save companion PDFs, covers, chapter lists and annotations where available
- Resume interrupted downloads and revisit earlier batches
- Set limits for simultaneous downloads, conversions and bandwidth per download
- Transfer sounds and macOS notifications

### Conversion and editing

- Convert downloads or local audio to M4B, M4A or MP3
- Convert local audio without signing in to Audible
- Save one file with chapter markers or separate files with chapter titles and track numbers
- Join multipart books into one file
- Copy compatible AAC audio without re-encoding, including separate M4A or M4B chapter files
- Preview parts and chapters and choose which sections to include in a new M4B while keeping the source files intact
- Keep available book metadata and cover art

### Files and playback

- Custom folder and filename templates
- Find missing or damaged files and repair the archive
- Import original Audible files or M4Bs into Apple Books

## Build and run

To build from source, you’ll need an Apple silicon Mac with Xcode 27.2, uv, and Rosetta. The build produces a universal app for macOS 15 and later. The first build downloads the Audible helper’s dependencies and compiles FFmpeg and LAME for both architectures. Later builds reuse the tools. [Xcode](https://developer.apple.com/xcode/) · [Install uv](https://docs.astral.sh/uv/getting-started/installation/) · [Install Rosetta](https://support.apple.com/en-gb/102527)

Xcode resolves the pinned Sparkle update framework through Swift Package Manager.

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

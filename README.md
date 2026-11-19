# DownAudible

DownAudible backs up your Audible library on a Mac. Keep the files Audible sends you, or make chaptered M4Bs for Apple Books and other audiobook players.

## Build and run

You’ll need an Apple silicon Mac, [Xcode 27.2](https://developer.apple.com/xcode/), and [uv](https://docs.astral.sh/uv/getting-started/installation/). The app runs on macOS 15 and later. The first build has to fetch the Audible helper’s dependencies and compile FFmpeg. Later builds reuse the tools.

Open `DownAudible.xcodeproj` in Xcode, choose the **DownAudible** scheme, and press Command-R. To build from Terminal instead, run

```sh
xcodebuild -scheme DownAudible -configuration Debug -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/DownAudible.app
```

Xcode uses automatic signing. The checked-in settings sign local builds to run on your Mac. To build with an Apple development team, create `Signing.local.xcconfig` beside `App.xcconfig` and set `DEVELOPMENT_TEAM` to your team ID and `CODE_SIGN_IDENTITY` to `Apple Development` there. Git ignores this file.

## Accounts

Choose the marketplace that holds your books and sign in to Amazon in your browser. Paste the resulting address into DownAudible when prompted. Use **Settings → Accounts** to add, name, and switch between accounts. DownAudible saves each session in your Mac’s Keychain.

You can also import a profile from Audible CLI’s `config.toml` or select an Audible CLI authentication file directly. Encrypted files need the password you chose in Audible CLI.

Select books in **Library**, then choose **Download Selected**. You can also download the entire library from the **Audiobooks** menu. The download sheet lets you add companion PDFs and cover images when Audible has them. To save just the extras, uncheck **Download audio**. Select **Convert to M4B** to make an audiobook with its chapters and tags. **Keep the original after conversion** is on by default.

DownAudible asks for AAX first. It can also save AAXC and the other formats Audible delivers for particular titles. The **Transfers** view shows progress and lets you cancel a batch or retry unfinished books. An interrupted batch can be started again from the library. DownAudible reuses its completed files.

If you’ve already downloaded your books, use **Match Existing Folder** in **Library**. DownAudible uses book IDs and tags to match files it recognises. You can also use a book’s contextual menu to choose its file yourself. DownAudible reads matched files in place.

The **Export Library** menu saves the current library as JSON, CSV, or TSV. You can set purchase dates, podcast handling, and the page size under **Settings**.

## Convert files you already have

In **Convert Files**, add a file or a whole folder, then choose **Convert All**. The converter reads AAX, AAXC, legacy AA, and MP3. For an encrypted AAX made with another account, enter that account’s eight-character activation code in **Convert Files**. An AAXC needs its saved licence or a compatible `.voucher` file beside it.

The converter copies compatible AAC audio into the M4B and re-encodes when needed. It carries over chapters and artwork where available. If Audible delivers a book in parts, DownAudible saves the original parts and combines them into one M4B when you turn conversion on.

## Folder templates

Set the destination and template in **DownAudible → Settings**. You can use `{format}`, `{author}`, `{title}`, and `{asin}`. Slashes in the template create folders. The default `{format}/{author}/{title}` gives each format its own directory.

```text
aax/Me/My Great Book/My Great Book.aax
m4b/Me/My Great Book/My Great Book.m4b
```

## Download settings

Choose the original format and quality in Settings. You can also set cover sizes, save chapter and annotation JSON, and choose how to name files. Job settings control how many transfers can run at once, the bandwidth allowed for each download, the network timeout, and whether to continue a batch after an error.

Run `Scripts/check-archive.sh` to check folder templates, file matching, and local exports without an Audible account.

## Credits

DownAudible is developed by [Ashley Cox](https://ashleycox.co.uk/) and licensed under the [GNU Affero General Public License, version 3](LICENSE).

The Audible helper uses [Audible](https://github.com/mkb79/Audible) by mkb79 and draws on [Audible CLI](https://github.com/mkb79/audible-cli). [Libation](https://github.com/rmcrackan/Libation) and [AAX Audio Converter](https://github.com/audiamus/AaxAudioConverter) were references for the download and conversion workflow. The bundled [FFmpeg](https://ffmpeg.org/) tools use an LGPL build. The [build script](Scripts/prepare-media.sh) pins the source and applies the [local patches](Scripts/Media).

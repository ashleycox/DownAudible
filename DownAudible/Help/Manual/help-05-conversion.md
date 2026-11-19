# Converting Audio

## Convert a download

Turn on conversion in the download sheet. **Keep the original after conversion** keeps the Audible files alongside the converted output. Turn it off if you only want the converted copy. If a chapter or tag is missing from the source, DownAudible uses the information Audible supplies when available.

## Convert files already on your Mac

Open **Convert Files**, then click **Add Files** or **Add Folder**. DownAudible reads AAX, AAXC, AA, MP3, M4A, and M4B. You can also choose **Open Audio Files** or **Open Audio Folder** from the **File** menu. You can drag files in from Finder as well. Choose the destination and format at the bottom of Convert Files. Open **Conversion Options** to change chapter and audio settings.

Select rows and click **Convert Selected**. With nothing selected, **Convert All** starts the whole list. Control-click a row for **Convert**, **Show in Finder**, **Add to Apple Books**, or **Copy Path**. **Remove from List** and **Clear List** only change the list.

Encrypted AAX files need the eight hexadecimal activation bytes for the account that downloaded them. DownAudible can use the active account’s bytes. Enter the original account’s bytes when converting files from another account. AAXC files need their saved licence or a compatible `.voucher` beside the book. Keep multipart audio and companion files together when moving them.

## Format and chapters

In **Settings > Conversion**, choose **M4B**, **M4A**, or **MP3**. An M4B is the usual choice for an audiobook with chapters in one file. You can keep a book in one file or write a separate file for each chapter.

**Copy audio when possible** preserves the AAC audio stream when the source and settings allow it. **Always encode** writes a new stream. Choosing a bitrate, channel count, or sample rate can also require encoding. Separate chapter files are encoded so that each one starts at the chapter marker.

For MP3, **Automatic** can copy a compatible source. **Constant (CBR)** keeps one bitrate throughout the file. **Variable (VBR)** adjusts the bitrate as the audio changes, using the selected quality level. For a single file, turn on **Keep chapter markers** to retain navigation. **Keep book metadata** and **Embed cover image** control the book tags and cover in the output.

## Choose settings for a player

For Apple Books, use one M4B and keep chapter markers on. For a player that sorts and plays MP3 files but ignores markers inside them, choose MP3 and **One file per chapter**. Put `{chapterNumber}` before `{chapter}` in the filename template so Finder sorts the tracks in order.

If a player requires mono or a particular sample rate, set **Channels** and **Sample rate** before starting. At low MP3 sample rates, some high bitrates are unavailable. Use a lower bitrate or a higher sample rate if Settings flags the combination.

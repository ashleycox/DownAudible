# Converting Audio

## Convert a download

Turn on conversion in the download sheet. **Keep the original after conversion** keeps the Audible files alongside the converted output. Turn it off if you only want the converted copy. If a chapter or tag is missing from the source, DownAudible uses the information Audible supplies when available.

If DownAudible cannot unlock an AAX download for conversion, it refreshes the activation bytes for the account used for the download and tries the file again.

## Convert files already on your Mac

Open **Convert Files**, then click **Add Files…** or **Add Folder…**. DownAudible reads AAX, AAXC, AA, MP3, M4A, and M4B. You can also choose **Open Audio Files…** or **Open Audio Folder…** from the **File** menu, or drag files in from Finder. If a selection includes unsupported items, supported audio still appears in the list. Choose the destination and format at the bottom of Convert Files.

Choose **Audiobooks > Conversion Options…** to open Convert Files and change chapter and audio settings. From Convert Files, you can also click **Conversion Options…** or press Control–Shift–O.

Select rows and click **Convert Selected**. With nothing selected, **Convert All** starts the whole list. With Convert Files open, the **Audiobooks** menu includes actions for the file list. Control-click a row for **Convert**, **Show in Finder**, **Add to Apple Books**, or **Copy Path**. **Remove from List** and **Clear List** only change the list.

Encrypted AAX files need the eight hexadecimal characters from the account that downloaded them. Leave **Activation bytes (optional)** blank to use the active account and let DownAudible refresh its code if needed. For a file from another account, enter the original account’s code in that field. To fix an activation error, correct the code and retry the transfer.

AAXC files need their saved licence or a compatible `.voucher` beside the book. Keep multipart audio and companion files together when moving them.

## Format and chapters

In **Settings > Conversion**, choose **M4B**, **M4A**, or **MP3**. An M4B is the usual choice for an audiobook with chapters in one file. You can keep a book in one file or write a separate file for each chapter.

**Copy audio when possible** preserves a compatible audio stream. **Always encode** writes a new stream. Choosing a bitrate, channel count, or sample rate can also require encoding. DownAudible encodes separate chapter files so that each one starts at the chapter marker.

For MP3, **Constant (CBR)** keeps one bitrate throughout the file. **Variable (VBR)** adjusts the bitrate as the audio changes, using the selected quality level. For a single file, turn on **Keep chapter markers** to retain navigation. **Keep book metadata** and **Embed cover image** control the book tags and cover in the output.

## Choose settings for a player

For Apple Books, use one M4B and keep chapter markers on. For a player that sorts MP3 files by filename, choose MP3 and **Separate chapter files**. Put `{chapterNumber}` before `{chapter}` in the chapter filename template to sort the tracks in order.

If a player requires mono or a particular sample rate, set **Channels** and **Sample rate** before starting. At low MP3 sample rates, some high bitrates are unavailable. Use a lower bitrate or a higher sample rate if Settings flags the combination.

## Related chapters

[Downloading Books](help-04-downloads.md)

[Naming and Folders](help-06-files.md)

[Audible Tools](help-08-audible-tools.md)

## Keyboard Shortcuts

| Command | Shortcut |
| --- | --- |
| Convert Files | Command–3 |
| Add Files… | Command–O |
| Add Folder… | Shift–Command–O |
| Choose a destination folder | Control–Shift–Y |
| Conversion Options… | Control–Shift–O |
| Convert All / Convert Selected | Control–Shift–V |
| Show in Finder | Control–Shift–S |
| Add to Apple Books | Control–Shift–B |

[See all keyboard shortcuts](help-10-keyboard-shortcuts.md)

---

## Support DownAudible

If this app has helped you, a donation is one way to support my work. There’s no pressure or hard sell. DownAudible is and always will be free.

[Make a donation](https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE)

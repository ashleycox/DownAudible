# Naming and Folders

## Destination

Choose where to save your archive in **Settings > Files**. A download sheet can also change the destination. To link audio from an existing archive, choose **Match Existing Folder…** in Library and select the archive folder.

## Verify and repair the archive

Choose **Audiobooks > Library > Verify and Repair Archive…** or use the same command in **Library Actions**. DownAudible checks the current account’s archive destination and matched audio for a complete copy of each book. It decodes MP3, M4A, and M4B audio to check playback. For protected Audible files, it checks the file structure and any recorded size. Choose **Cancel** to stop the check.

The report lists titles with missing, incomplete, or unreadable audio. Select titles in the report or choose **Select All Repairable**. Choose **Repair Selected** or **Repair … Titles** to add just those titles to **Downloads**. Repair resumes valid partial audio when possible and uses your current audio download and conversion settings. DownAudible saves replacement audio alongside existing files. If Audible no longer offers a title for download, the report shows it as unavailable.

## Templates

Use a slash to start another folder. With the default template `{format}/{author}/{title}`, an AAX and its M4B copy go into separate folders.

`aax/Me/My Great Book/My Great Book.aax`  
`m4b/Me/My Great Book/My Great Book.m4b`

Tokens in braces are replaced with information about the book or file. For example, `{format}` becomes `aax`, `aaxc`, `m4b`, or another actual format, and `{asin}` is Audible’s book identifier. Use `{author}` and `{title}` to arrange an archive for browsing. When a label contains characters that cannot go into a Mac filename, DownAudible substitutes safe ones.

Use `{title}`, `{subtitle}`, `{author}`, `{authors}`, `{narrator}`, `{narrators}`, `{series}`, `{seriesNumber}`, `{publisher}`, `{year}`, `{language}`, `{asin}`, and `{format}` for book and format details. The chapter tokens `{chapter}` and `{chapterNumber}` apply to the separate chapter files. Use `{partNumber}` for a multipart original. A field may be blank if the book lacks that detail. The preview shows the result for a sample title. Click **Restore Default Template** to return the folder template to `{format}/{author}/{title}`.

## Filename rules

Use **Filename template** to name the files themselves. Leave it blank to use **Name files by**. **Chapter filename template** controls names when conversion creates separate chapter files. Put slashes only in **Folder template**. DownAudible adds the extension from the actual file format.

Choose how to handle spaces and letter case. Leave them alone to keep the source spelling, or use hyphens, underscores, lowercase, or uppercase. **Use ASCII characters** can help with older players. The filename length limit is measured in bytes and includes the extension. **If a file is already saved** controls whether DownAudible reuses it or saves another copy.

Turn on **Keep Audible’s AAX filename** in **Settings > Files** to use the filename Audible supplies for newly saved AAX downloads. The name comes from the download response or its URL. If the name is missing, cannot be used as a Mac filename, or exceeds your length limit, DownAudible uses your filename rules. When a name is already taken, DownAudible adds a suffix to save the new file. The folder template still determines where the AAX goes. Converted audio uses your filename rules.

## Apple Books

Choose **Settings > Downloads > Apple Books** to send newly saved files to the Books app after a transfer. Select **Original Audible file** or **M4B**. For M4B, enable conversion and select M4B in **Settings > Conversion**. Books may ask you to authorise an original Audible file. Check the transfer result if Books cannot open it.

## Related chapters

[Downloading Books](help-04-downloads.md)

[Converting Audio](help-05-conversion.md)

[Downloads and Recovery](help-07-transfers.md)

## Keyboard Shortcuts

| Command | Shortcut |
| --- | --- |
| Settings… | Command–Comma |
| Choose a destination folder in Files settings | Control–Shift–Y |
| Restore Default Template | Control–Shift–D |
| Show Output in Finder from Downloads | Control–Shift–F |
| Add to Apple Books from Downloads | Control–Shift–B |

[See all keyboard shortcuts](help-10-keyboard-shortcuts.md)

---

## Support DownAudible

If this app has helped you, a donation is one way to support my work. There’s no pressure or hard sell. DownAudible is and always will be free.

[Make a donation](https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE)

# Naming and Folders

## Destination

Choose where to save your archive in **Settings > Files**. A download sheet can also change the destination. Keep the same destination and naming settings when picking up an existing archive so DownAudible can find its files.

## Templates

Use a slash to start another folder. With the default template `{format}/{author}/{title}`, an AAX and its M4B copy go into separate folders.

`aax/Me/My Great Book/My Great Book.aax`  
`m4b/Me/My Great Book/My Great Book.m4b`

Tokens in braces are replaced with information about the book or file. For example, `{format}` becomes `aax`, `aaxc`, `m4b`, or another actual format, and `{asin}` is Audible’s book identifier. Use `{author}` and `{title}` to arrange an archive for browsing. When a label contains characters that cannot go into a Mac filename, DownAudible substitutes safe ones.

Use `{title}`, `{subtitle}`, `{author}`, `{authors}`, `{narrator}`, `{narrators}`, `{series}`, `{seriesNumber}`, `{publisher}`, `{year}`, `{language}`, `{asin}`, and `{format}` for book and format details. The chapter tokens `{chapter}` and `{chapterNumber}` apply to the separate chapter files. Use `{partNumber}` for a multipart original. A field may be blank if the book lacks that detail. The preview shows the result for a sample title. Click **Restore Default Template** to return the folder template to `{format}/{author}/{title}`.

## Filename rules

Use **Filename template** to name the files themselves. Leave it blank to use **Name files by**. **Chapter filename template** controls names when conversion creates separate chapter files. Put slashes only in **Folder template**. DownAudible adds the extension from the actual file format.

Choose how to handle spaces and letter case. Leave them alone to keep the source spelling, or use hyphens, underscores, lowercase, or uppercase. **Use ASCII characters** can help with older players. The filename length limit is measured in bytes and includes the extension. **If a file is already saved** controls whether DownAudible reuses it or saves another copy.

## Apple Books

Choose **Settings > Downloads > Apple Books** to send newly saved files to the Books app after a transfer. Select **Original Audible file** or **M4B**. For M4B, enable conversion and select M4B in **Settings > Conversion**. Books may ask you to authorise an original Audible file. Check the transfer result if Books cannot open it.

---

## Support DownAudible

If this app has helped you, a donation is one way to support my work. There’s no pressure or hard sell. DownAudible is and always will be free.

[Make a donation](https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE)

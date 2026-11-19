# Troubleshooting and Shortcuts

## Sign-in or account trouble

If the address is rejected, open the sign-in page again, finish in your browser, and copy the full address of the final page. Check that the selected marketplace is the one where you bought the books. If you recently changed your Amazon credentials, sign out of the saved session and sign in again.

## A book is unavailable

Audible may withhold a download for a preorder, expired loan, or catalogue title that has left your subscription. Refresh the library to check again. If you have a local file, match it to the book or open it in **Convert Files**.

## A local file cannot be converted

Check that the source is still in the folder you added or matched. If it is AAX, check which account downloaded it and use that account’s activation bytes. If it is AAXC, look for the corresponding voucher. If the destination is on an external disk, reconnect the disk and check that Finder can write to the folder.

## The archive is on a disk that has been disconnected

Reconnect the disk, make sure the destination still points to the archive, and choose **Recheck Saved Files**. If you moved files inside or outside the archive, use **Match Existing Folder** again or update individual matches. Use **Download Missing** if the files are gone and you want to replace them.

## A download keeps failing or restarts at zero

Check the error in **Transfers**. Try lowering simultaneous downloads or setting a longer request timeout. **Retry** uses any valid partial file. Audible can supply a different file or a server that does not support byte ranges, in which case DownAudible starts from zero. Use **Restart Download** from the transfer’s contextual menu if you want to discard the partial audio yourself.

## Books opens without the audiobook

Find the file with **Show Audio in Finder**. Books may require authorization for an original or may not accept that particular Audible format. Use **Convert Files** to create one M4B, then choose **Add to Apple Books** on the result in Transfers. Check Books itself to confirm that it imported the file.

## Useful keys

**Command-O** opens audio files. **Shift-Command-O** opens a folder of audio. Use **Command-1**, **Command-2**, or **Command-3** to show Library, Transfers, or Convert Files.

**Command-R** refreshes the Audible library. **Command-D** downloads the selected books. **Shift-Command-D** opens Download Missing. **Command-comma** opens Settings. **Shift-Command-/** opens this manual.

Choose **Window > Show DownAudible** to bring the main window back if it is hidden or closed. The View menu has the standard sidebar controls.

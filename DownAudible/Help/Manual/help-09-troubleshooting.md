# Troubleshooting

## Sign-in or account trouble

If the address is rejected, open the sign-in page again, finish in your browser, and copy the full address of the final page. Check that the selected marketplace is the one where you bought the books. If you recently changed your Amazon credentials, sign out of the saved session and sign in again.

## A book is unavailable

Audible may withhold a download for a preorder, expired loan, or catalogue title that has left your subscription. Refresh the library to check again. If you have a local file, match it to the book or open it in **Convert Files**.

## A local file cannot be converted

Check that the source is still in the folder you added or matched. If it is AAX, check which account downloaded it and use that account’s activation bytes. If it is AAXC, look for the corresponding voucher. If the destination is on an external disk, reconnect the disk and check that Finder can write to the folder.

## The archive is on a disk that has been disconnected

Reconnect the disk, make sure the destination still points to the archive, and choose **Recheck Saved Files**. If you moved files inside or outside the archive, use **Match Existing Folder** again or update individual matches. Use **Download Missing** if the files are gone and you want to replace them.

## A download keeps failing or restarts at zero

Check the error in **Transfers**. Try lowering simultaneous downloads or setting a longer request timeout. **Retry** uses any valid partial file. Audible can supply a different file or a server that does not support byte ranges, in which case DownAudible starts from zero. Use **Restart Download…** from the transfer’s contextual menu to discard the partial audio and start again.

## Books opens without the audiobook

Find the file with **Show Output in Finder** in Transfers. Books may require authorisation for an original or may refuse that particular Audible format. Use **Convert Files** to create one M4B, then choose **Add to Apple Books** on the result in Transfers. Check Books itself to confirm that it imported the file.

## The main window is closed

Choose **Window > Show DownAudible** to bring the main window back. Use the **View** menu to show or hide the sidebar and the library status bar. Choose **Help > Keyboard Shortcuts** for the full list of keys.

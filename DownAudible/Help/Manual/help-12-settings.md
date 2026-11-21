# Settings Reference

Choose **DownAudible > Settings…** or press Command–Comma. Open this chapter directly from **Help > Settings Reference**. The setup assistant uses the same settings. Choose **Help > Set Up DownAudible…** to open it again.

## General

| Setting | What it does |
| --- | --- |
| Check for updates automatically | Checks for new DownAudible releases in the background. Your choice at the update prompt sets the initial value. |
| Install updates automatically | Downloads updates in the background and installs them when you quit DownAudible. Turn on automatic checking to use it. |
| Check for Updates… | Looks for a new release now. |
| Show Help Tags | Shows short descriptions when you point to supported controls. On by default. |

## Accounts

| Setting | What it does |
| --- | --- |
| Audible Accounts | Lists your saved accounts, their marketplaces and the status of the active account. Select an account to see its available actions. |
| Add Account… | Adds an Audible account using browser sign-in. Choose its marketplace and, if you want, give the profile a name. |
| Import from Audible CLI… | Adds a profile from an Audible CLI configuration or authentication file. Enter the file’s password if it is encrypted. |
| Sign In… | Reconnects the active profile after signing out. |
| Sign Out | Clears the saved sign-in for the active profile. You can sign in to the profile again later. |
| Switch to This Account | Makes the selected profile active and opens its library when signed in. |
| Rename… | Changes how the selected account is named within DownAudible. |
| Remove Account… | Removes the selected profile and its saved sign-in and file matches from DownAudible. The app asks for confirmation. |

See [Accounts and Sign-In](help-02-accounts.md) for the browser flow, legacy usernames and Audible CLI imports.

## Library

| Setting | What it does |
| --- | --- |
| Podcasts | **Hide podcasts** is the default. Choose **Show podcast series** to list series or **Show individual episodes** to list the episodes. |
| Books per request | Sets the number of results requested from Audible at a time when loading your library. The default is 100. Enter a value from 10 through 1,000. |
| Purchased on or after | Enables an inclusive start date for loading the library. Turn it off to omit the start date. Off by default. |
| Purchased on or before | Enables an inclusive end date for loading the library. Turn it off to omit the end date. Off by default. |
| Refresh Library | Reloads the active library after you change the podcast, request size or date settings. |
| Suggest filter values as you type | Uses the active library to suggest matches when you enter a table filter. On by default. |

The purchase date settings affect which titles the library loads. Use **Filter Library** in the toolbar or **View** menu to narrow the loaded table. See [Library and File Matching](help-03-library.md).

## Downloads

| Setting | What it does |
| --- | --- |
| Download audio | Fetches audio when you download a title. On by default. Turn it off to request companion files only. |
| Download format | **AAX with fallback** is the default. It tries AAX, then AAXC if needed. **AAX only** requires AAX. **AAXC** requests AAXC directly. |
| Download quality | Requests **Best**, **High** or **Normal** from Audible. The default is **Best**. The available audio depends on the title and marketplace. |
| Prefer whole-book downloads | Tries to download the whole book in one file before requesting parts. On by default. Turn it off to request individual files for titles Audible lists as multipart. |
| Convert to M4B, M4A or MP3 | Creates a playable copy in the format selected in **Conversion**. Off by default. The label shows your chosen file format. |
| Keep the original after conversion | Saves the original download as well as the converted copy. On by default. This setting applies when both audio downloading and conversion are on. |
| Download companion PDFs | Saves PDFs supplied by Audible for the title. Off by default. |
| Save cover images | Saves artwork as separate image files. Off by default. |
| Save chapters as JSON | Writes Audible’s chapter list as a separate file. Off by default. |
| Chapter file layout | **Nested chapters** is the default. Choose **Flat chapter list** to write the chapter details as one list. Applies when saving chapters as JSON. |
| Save annotations as JSON | Writes bookmarks, notes and other annotations supplied by Audible as a separate file. Off by default. |
| Cover sizes | Requests one or more of the listed pixel sizes. All boxes start unchecked, which uses the largest cover available. **Use Largest Available** clears the selections. |
| Add after saving | Sends files to Apple Books. Choose **Off** (the default), **Original Audible file** or **M4B**. For M4B, turn conversion on and select **M4B** in **Conversion**. |

See [Downloading Books](help-04-downloads.md) and [Naming and Folders](help-06-files.md).

## Conversion

| Setting | What it does |
| --- | --- |
| File format | **M4B** is the default audiobook format. Choose **M4A** for AAC audio or **MP3** for players that require it. |
| Chapters | **One file** is the default. Choose **Separate chapter files** to export one file for each chapter. |
| Keep chapter markers | Embeds chapter markers when exporting one file. On by default. |
| Encoding | With one file, **Copy audio when possible** keeps a compatible audio stream. **Always encode** writes a new stream. Choosing specific audio parameters can require encoding. |
| Copy chapter audio when possible | Copies compatible AAC into separate M4B or M4A chapter files without encoding. Off by default. Set **Bitrate** to **Automatic** and **Channels** and **Sample rate** to **Match source** to use it. Some players may play extra audio at the edge of a copied chapter. |
| Bitrate mode | For MP3, **Automatic** is the default. **Constant (CBR)** keeps the same bitrate throughout the file. **Variable (VBR)** adjusts the bitrate and uses **Quality**. |
| Quality | For variable bitrate MP3, choose from **Highest quality (V0)** through **Smallest file (V8)**. The default is **High quality (V2)**. |
| Bitrate | **Automatic** is the default. You can choose a listed bitrate between 32 and 320 kbps. The supported rate depends on file format, sample rate and channels. With MP3 variable bitrate, choose **Quality** instead. |
| Channels | **Match source** is the default. Choose **Mono** or **Stereo** if your player requires it. |
| Sample rate | **Match source** is the default. Choose a listed rate from 8 through 48 kHz when a player requires a particular rate. |
| Keep book metadata | Includes available title, author, narrator and other book tags. On by default. |
| Embed cover image | Includes available artwork inside the converted audio file. On by default. |
| Move converted AAX files to Trash | Applies to MP3 exports only. Off by default. After a complete export, moves an AAX you queued in **Convert Files** or an eligible DownAudible archive original to the Mac’s Trash. For archive originals, turn off **Keep the original after conversion**. Library jobs leave matched files where they are. |

See [Converting Audio](help-05-conversion.md) for chapter layouts, source credentials and choosing formats for different players.

## Files

| Setting | What it does |
| --- | --- |
| Save to | Shows the archive’s destination. Use **Choose…** to change it. The default is the **Audiobooks** folder in your Documents folder. |
| Folder template | Controls the subfolders for saved files. Use slash-separated folder names and tokens. The default is `{format}/{author}/{title}`. **Restore Default Template** restores the default. |
| Keep Audible’s AAX filename | Uses the filename supplied by Audible for a newly saved AAX if it fits the filename rules. Off by default. |
| Filename template | Controls the name of each file. Leave it blank to use **Name files by**. The format determines the extension. |
| Chapter filename template | Controls each separate chapter’s filename. The default is `{title} - {chapterNumber} - {chapter}`. |
| Name files by | **Title** is the default. Choose **Title (ASCII)**, **ASIN and title**, **ASIN and title (ASCII)** or **ASIN only** to change naming when **Filename template** is blank. |
| Maximum filename length | Limits filenames, including the extension, to 40 through 230 bytes. The default is 230 bytes. |
| Spaces | **Keep spaces** is the default. Choose **Use hyphens** or **Use underscores** to replace spaces in names. |
| Letter case | **Keep original case** is the default. Choose **Lowercase** or **Uppercase** to change the case of names. |
| Use ASCII characters | Converts names to ASCII characters for older players. Off by default. |
| If a file is already saved | **Reuse completed files** is the default. Choose **Save another copy** to save a new output with a unique name. |
| Template preview | Shows an example path, lists the available tokens and flags invalid templates. |

See [Naming and Folders](help-06-files.md) for the full list of tokens and file naming examples.

## Jobs

| Setting | What it does |
| --- | --- |
| Simultaneous downloads | Sets how many downloads can run at once, from 1 through 12. The default is 3. |
| Simultaneous conversions | Sets how many conversions can run at once, from 1 through 12. The default is 2. |
| Request timeout | Limits how long DownAudible waits for a request, from 0 through 600 seconds. The default is 45 seconds. Enter 0 to turn off the timeout. |
| Bandwidth per download (kbps) | Caps each running download’s bandwidth. **Unlimited** is the default. Choose a preset or **Custom** and enter **Custom bandwidth (kbps)**. |
| Continue after a job fails | Lets other jobs run after a failure. On by default. Turn it off to stop waiting jobs after an error. |
| Show detailed transfer progress | Shows progress for active transfers and the queue. On by default. |
| Log | **Off** is the default. Choose **Errors only** to record failures or **Transfer results** to record outcomes. |
| Log file | Shows the log location when logging is on. Use **Choose…** to set a location or **Use Default Location** to return to `~/Library/Application Support/DownAudible/Transfers.log`. |

See [Downloads and Recovery](help-07-transfers.md) for queue controls.

## Notifications

| Setting | What it does |
| --- | --- |
| Permission | Shows whether DownAudible can post macOS notifications. Opening the pane checks the current permission without prompting. |
| Notification Center | Shows whether macOS displays DownAudible notifications in Notification Center. |
| Banners and Alerts | Shows whether macOS lets DownAudible display banners or alerts. |
| Enable Notifications | Asks macOS to allow notifications for DownAudible. |
| Open Notification Settings | Opens Notifications in macOS System Settings. The status updates when you return to DownAudible. |
| Send Test Notification | Posts a silent test when Notification Center delivery is available. |
| Transfer Events | Select **Download Completed**, **Conversion Completed**, **Download Failed**, **Conversion Failed**, or **Queue Finished**. Each row shows the event name and its current delivery mode. |
| Delivery | **Off** is the default. Choose **Notification Only** for a silent macOS notification, **Sound Only** for a sound, or **Both**. macOS controls whether alerts appear in Notification Center or as banners. **Queue Finished** offers **Off** and **Sound Only**. |
| Sound | Shows built-in chimes and macOS sounds together. Focus the list and use Up or Down Arrow to select and preview a sound. **Soft Bell** is the initial selection. |
| Choose Sound File… | Imports and previews an audio file. The file appears under **Custom Sound** in the list. Use the same button to replace it. The current sound stays selected until the new file is ready. |
| Play Sound | Plays the selected sound again. |

DownAudible groups each outcome into one alert when an active queue or retry finishes. Click a transfer notification to go to its jobs in **Downloads**. If enabled, **Queue Finished** plays after the outcome sounds, including for retries that only send saved audio to Books. Cancelled queues and restored history are quiet.

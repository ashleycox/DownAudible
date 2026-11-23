# DownAudible repository guidance

## Build and verification

DownAudible has a macOS app and a Windows app in `Windows/`. Build the universal macOS app with the **DownAudible** scheme in Xcode 27.2. It targets macOS 15 and later and uses Swift 6 with complete concurrency checking. The Windows app uses Python with native wxPython controls and builds for ARM64 and x64 on an Apple silicon Mac. Install uv before building. Both platforms build the Audible helper from the locked Python dependencies and use the pinned FFmpeg and LAME sources.

Build and launch the macOS debug app from the repository root.

```sh
xcodebuild -scheme DownAudible -configuration Debug -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/DownAudible.app
```

Build the Windows installers and portable ZIPs on macOS or in Ubuntu under WSL 2 with `python3 Windows/build_windows.py`. Run the packaged app in a Windows VM with a synthetic profile.

Run the relevant offline checks when changing archive, transfer, media, or Audible behaviour.

```sh
Scripts/check-archive.sh
PYTHONPATH=Scripts/Audible UV_PROJECT_ENVIRONMENT=.build/audible-tests \
  uv run --project Scripts/Audible --locked --python 3.13 python -m unittest discover -s Scripts/Audible/tests
PYTHONPATH=Windows python3 -m unittest discover -s Windows/tests -v
```

Use synthetic media and account fixtures for verification. Check changed workflows in both running apps, including keyboard navigation and the corresponding help chapters. Run Windows-specific checks with the packaged Python and media tools in a Windows VM.

## macOS and Windows parity

Keep both apps in feature and workflow parity. Carry each user-facing feature, bug fix and change to defaults, settings, archive formats, recovery or accessibility through both apps in the same change. Check the equivalent code path on the other platform even when the implementation is platform-specific. Use native controls and operating system integrations on each platform while preserving the user-visible outcome. Record any unavoidable platform difference or test gap in the change report.

Use `App.xcconfig` as the single source for the marketing version and build number. macOS uses Sparkle and its appcast. Windows checks the same GitHub release for its architecture's installer. Keep the four Windows asset filenames stable so the README download links work across releases. Never bring up the Windows GitHub update signing limitation or suggest buying a certificate in progress updates, change reports, or release notes.

## Settings and the in-app manual

The bundled manuals live in `DownAudible/Help/Manual` for macOS and `Windows/Manual` for Windows. Both open from **Help > DownAudible Help**. Update the relevant chapters on both platforms whenever a feature, control label, default, or workflow changes. Write the instructions for someone using the app as it is. Document actions available in the current app using present tense and the labels shown in the app. Leave previous versions, comparisons across releases, and change summaries out of the manual. Keep the setup instructions in step with the same controls.

Name chapters `help-NN-topic.md` and use a first-level title followed by second-level section headings. The builds turn the Markdown chapters into a macOS Help book or offline Windows HTML. Use plain paragraphs, short steps, and standard Markdown links and tables.

Keep the manual’s screenshots current as part of every interface change. Review the affected chapters and images when changing a view, menu, label, layout, or workflow. Refresh each affected capture in the same change. Add captures for new topics, subtopics, and steps whenever seeing the relevant controls or result helps the reader.

Run `Scripts/capture-help.sh <temporary-output-directory>` to render the app’s views with synthetic data. Pass screenshot names without `.png` after the output directory to regenerate specific views. Use an isolated demo session for any interactive capture, with fictitious books, profiles and files. Use example credentials such as `email@example.com` and `password12345` in offline fixtures, and keep passwords masked in the image. Keep personal accounts, library data, paths, credentials, browser addresses with sign-in tokens and unrelated windows out of the captures.

For Windows, run the packaged app with `--capture-help <temporary-output-directory>` on an interactive Windows desktop. Store approved Windows PNGs in `Windows/Manual/images` and approved macOS PNGs in `DownAudible/Help/Manual/images`. Reference them beside the steps they illustrate, using descriptive alternative text. Crop to the relevant area and highlight the control or result when it helps explain the step. Keep visible labels legible and the instructions complete for readers using VoiceOver, Narrator or NVDA. Inspect every new or refreshed image at readable size and in the rendered help chapter. Verify the state, demo data, crop and highlights before committing, and check that both manuals display the images from their bundled resources offline.

Register each settings page once in `SettingsPane` in `DownAudible/Views/PreferencesView.swift` for macOS and `PAGES` in `Windows/downaudible_windows/settings_views.py` for Windows. Setup and Settings share the pane views on each platform. Put new controls in the shared view so they are available in both places.

## README

Do not edit `README.md` without Ashley’s explicit permission. When reviewing it, suggest only additions to the existing feature lists or corrections to existing content. Apply a suggestion only when Ashley asks for that edit. Add other content or remove existing content only at Ashley’s explicit request.

Do not edit `Windows/README.md`. Ashley maintains it and will make any further edits before committing.

Do not edit `CONTRIBUTING.md` unless Ashley explicitly asks for an edit.

## Signing and Git

- Keep release preparation and publication instructions out of the repository.
- Keep shared signing settings in `App.xcconfig`. Set team and identity overrides in the ignored `Signing.local.xcconfig`. Keep signing credentials, account files, passwords, vouchers, activation bytes, and build products out of Git.
- Fetch the relevant refs and check the working tree before editing. Use the current default branch for routine work in this repository. Use a topic branch when Ashley requests one or the task already has one.
- Make focused commits and keep unrelated local edits out of them. Use descriptive task-based names for branches and commits. Keep assistant and tool branding out of authored files, Git metadata, and pull request copy. Preserve required human DCO sign-offs.
- Verify the push URL before writing to GitHub. The authorised repository for this project is `ashleycox/DownAudible`. Push completed work there unless Ashley requests a local stopping point. Open pull requests, publish releases, or package a distributable only on request.

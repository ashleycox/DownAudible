# DownAudible repository guidance

## Build and verification

DownAudible is an Apple silicon Mac app that targets macOS 15 and later. Use the **DownAudible** scheme in Xcode 27.2. Keep Swift 6 language mode and complete concurrency checking. Install uv before building. The build prepares the bundled Audible helper from locked Python dependencies and compiles the pinned FFmpeg and LAME sources.

Build and launch the debug app from the repository root.

```sh
xcodebuild -scheme DownAudible -configuration Debug -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/DownAudible.app
```

Run the relevant offline checks when changing archive, transfer, media, or Audible behaviour.

```sh
Scripts/check-archive.sh
PYTHONPATH=Scripts/Audible UV_PROJECT_ENVIRONMENT=.build/audible-tests \
  uv run --project Scripts/Audible --locked --python 3.13 python -m unittest discover -s Scripts/Audible/tests
```

Use synthetic media and account fixtures for verification. Check changes to macOS workflows in the running app when possible, including keyboard navigation and the corresponding help chapter.

## Settings and the in-app manual

The bundled manual lives in `DownAudible/Help/Manual` and opens from **Help > DownAudible Help**. Update the relevant chapters whenever a feature, control label, default, or workflow changes. Write the instructions for someone using the app as it is. Document actions available in the current app using present tense and the labels shown in the app. Leave previous versions, comparisons across releases, and change summaries out of the manual. Keep the setup instructions in step with the same controls.

Name chapters `help-NN-topic.md` and use a first-level title followed by second-level section headings. The build turns the Markdown chapters into a macOS Help book. Use plain paragraphs, short steps, and standard Markdown links and tables.

Keep the manual’s screenshots current as part of every interface change. Review the affected chapters and images when changing a view, menu, label, layout, or workflow. Refresh each affected capture in the same change. Add captures for new topics, subtopics, and steps whenever seeing the relevant controls or result helps the reader.

Run `Scripts/capture-help.sh <temporary-output-directory>` to render the app’s views with synthetic data. Pass screenshot names without `.png` after the output directory to regenerate specific views. Use an isolated demo session for any interactive capture, with fictitious books, profiles and files. Use example credentials such as `email@example.com` and `password12345` in offline fixtures, and keep passwords masked in the image. Keep personal accounts, library data, paths, credentials, browser addresses with sign-in tokens and unrelated windows out of the captures.

Store the approved PNGs in `DownAudible/Help/Manual/images` and reference them beside the steps they illustrate, using descriptive alternative text. Crop to the relevant area and highlight the control or result when it helps explain the step. Keep visible labels legible and the instructions complete for readers using VoiceOver. Inspect every new or refreshed image at readable size and in the rendered help chapter. Verify the state, demo data, crop and highlights before committing, and check that the Help book displays the images from its bundled resources offline.

Register each settings page once in `SettingsPane` in `DownAudible/Views/PreferencesView.swift`. Setup and Settings use that list and share the pane views. Put new controls in the shared view so they are available in both places.

## README

Do not edit `README.md` without Ashley’s explicit permission. When reviewing it, suggest only additions to the existing feature lists or corrections to existing content. Apply a suggestion only when Ashley asks for that edit. Add other content or remove existing content only at Ashley’s explicit request.

## Signing and Git

- Keep shared signing settings in `App.xcconfig`. Set team and identity overrides in the ignored `Signing.local.xcconfig`. Keep signing credentials, account files, passwords, vouchers, activation bytes, and build products out of Git.
- Fetch the relevant refs and check the working tree before editing. Use the current default branch for routine work in this repository. Use a topic branch when Ashley requests one or the task already has one.
- Make focused commits and keep unrelated local edits out of them. Use descriptive task-based names for branches and commits. Keep assistant and tool branding out of authored files, Git metadata, and pull request copy. Preserve required human DCO sign-offs.
- Verify the push URL before writing to GitHub. The authorised repository for this project is `ashleycox/DownAudible`. Push completed work there unless Ashley requests a local stopping point. Open pull requests, publish releases, or package a distributable only on request.

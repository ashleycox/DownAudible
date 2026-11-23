# Contributing to DownAudible

## Set up a local checkout

Fork DownAudible on GitHub and clone your fork. Replace `YOUR-USERNAME` with your GitHub username. [DownAudible on GitHub](https://github.com/ashleycox/DownAudible)

```sh
git clone https://github.com/YOUR-USERNAME/DownAudible.git
cd DownAudible
git switch -c fix/describe-your-change
```

Follow the local build instructions for each platform. The Windows guide includes steps for running the app and its tests in a Windows VM. [macOS build and run](README.md#build-and-run) · [Windows build guide](Windows/BUILD.md)

## Keep both apps in step

Carry user-facing features and fixes through macOS and Windows in the same change. Check the equivalent workflow on both platforms and use native controls that provide the same outcome. Describe any platform differences in the pull request.

Run the checks relevant to the change. Use sample media and accounts to exercise the affected workflows in both running apps. For interface changes, check visual layout at small and large window sizes, keyboard navigation, focus order, and control names and states with VoiceOver on macOS and Narrator or NVDA on Windows. [macOS and shared checks](README.md#checks) · [Windows checks](Windows/BUILD.md#verify-changes)

Update the affected help chapters and screenshots when a control, label, layout, default, or workflow changes. Use the labels shown in the app, capture screenshots with sample data, and give each screenshot descriptive alt text. Check the images and instructions in the bundled help. [macOS manual](DownAudible/Help/Manual/README.md) · [Windows manual](Windows/Manual/README.md)

## Open a pull request

Keep commits focused and leave build output, credentials, and private account or library data out of Git. Push your branch to your fork and open a pull request against `ashleycox/DownAudible` on `main`. Describe the problem, what changed, how you tested it, and any checks you could not run.

DownAudible is licensed under the GNU Affero General Public License, version 3. [License](LICENSE)

## Support DownAudible

If you like DownAudible and you’d like to support my work, you can [make a donation](https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE). There’s no pressure or hard sell. DownAudible is and always will be free.

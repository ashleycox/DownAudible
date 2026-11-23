# Build DownAudible for Windows

The Windows project is a wxPython desktop application. Both the Windows and macOS apps use the Python Audible helper and the pinned FFmpeg and LAME sources in this repository.

## Build on Apple silicon

Install Python 3.12 or later, [uv](https://docs.astral.sh/uv/getting-started/installation/), and Xcode Command Line Tools. From the repository root, run the build:

```sh
python3 Windows/build_windows.py
```

The build uses Astral’s pinned standalone CPython archive with an isolated module path, target-specific wxPython wheels, LLVM-MinGW, and NSIS. The first build downloads and verifies the pinned tools and compiles the media binaries. Later builds reuse those tools from the temporary directory. On macOS versions earlier than 27, put makensis 3.13 on your PATH to produce installers. Portable ZIP builds can run without NSIS. Set `DOWNAUDIBLE_WINDOWS_CACHE` to retain the build cache in a different location.

The build writes installers and portable ZIPs for x64 and ARM64 to `Windows/dist`. Use `--arch arm64` or `--arch x64` to select an architecture, `--format installer` or `--format portable` to select an output format, and `--output` to choose an output directory. It reads the version and build number from `App.xcconfig` and records both in the installer, launcher and bundled Python app.

## Build on Windows

Use Ubuntu 24.04 in [Windows Subsystem for Linux 2](https://learn.microsoft.com/windows/wsl/install) on an x64 or ARM64 PC. If you need to install it, run this in PowerShell as an administrator and restart when prompted:

```powershell
wsl --install -d Ubuntu-24.04
```

Open Ubuntu from Start. Install the build dependencies and clone the repo into your Ubuntu home directory:

```sh
sudo apt update
sudo apt install ca-certificates clang curl git make patch python3 xz-utils
curl -LsSf https://astral.sh/uv/install.sh | sh
. "$HOME/.local/bin/env"
git clone https://github.com/ashleycox/DownAudible.git
cd DownAudible
python3 Windows/build_windows.py
```

If you already have a checkout in Ubuntu, run the build from that repository root. Keep any custom build cache in Ubuntu’s filesystem. The build downloads its pinned LLVM-MinGW and NSIS tools and accepts the same output options as the Mac build. Open the Windows output folder from Ubuntu with:

```sh
explorer.exe "$(wslpath -w "$PWD/Windows/dist")"
```

## Run in Windows

Run the matching architecture's installer and open **DownAudible** from Start. To use the portable app, extract the complete ZIP into a folder and launch `DownAudible.exe` inside it. The bundled runtime includes Python and the media tools.

From PowerShell in the portable or installed app folder, run with synthetic data:

```powershell
.\DownAudible.exe --demo
```

The demo opens with fictitious accounts and audiobooks in a fresh temporary profile. Omit `--demo` to work with your own library.

## Verify changes

To run local tests on macOS, have FFmpeg and FFprobe available on `PATH` or set `DOWNAUDIBLE_FFMPEG` and `DOWNAUDIBLE_FFPROBE` to specific binaries.

```sh
PYTHONPATH=Windows python3 -m unittest discover -s Windows/tests -v
```

Install wxPython and Markdown in the same Python environment to include the interface tests on macOS. Run Windows-specific tests with an installed or extracted package in a Windows VM. Copy the contents of `Windows/tests` to a separate folder in the VM, such as `C:\Temp\DownAudible-Tests`. From PowerShell in the folder containing `DownAudible.exe`, run:

```powershell
$env:DOWNAUDIBLE_FFMPEG = (Resolve-Path .\resources\Media\ffmpeg.exe).Path
$env:DOWNAUDIBLE_FFPROBE = (Resolve-Path .\resources\Media\ffprobe.exe).Path
.\python\python.exe -m unittest discover -s 'C:\Temp\DownAudible-Tests' -v
```

The packaged-runtime tests exercise browser sign-in, a credential verification prompt and DPAPI session storage with synthetic accounts. The demo smoke test uses sample data in place of the bundled Audible helper.

Launch the packaged app on an interactive Windows desktop to run the offline UI smoke test or capture the manual screenshots. Both options create a temporary profile with sample data:

```powershell
.\DownAudible.exe --capture-help C:\Temp\DownAudible-Help --smoke-test C:\Temp\DownAudible-Check.json
```

Move the relevant captures into `Windows/Manual/images` after checking the data, labels, and focus state. The Windows app renders the Markdown chapters locally and opens the offline manual from **Help > DownAudible Help**.

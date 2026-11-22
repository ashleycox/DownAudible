#!/bin/bash
set -euo pipefail

if (( $# < 1 )); then
    echo "Usage: $0 OUTPUT_DIRECTORY [SCREENSHOT_NAME ...]" >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$1"
output=$(cd "$1" && pwd)
shift
work=$(mktemp -d /tmp/downaudible-demo.XXXXXX)
trap 'rm -rf "$work"' EXIT
app="$work/DownAudible Help Capture.app"
mkdir -p "$app/Contents/"{MacOS,Resources,Frameworks} "$work/Demo Audiobooks" "$work/Demo Audio" "$work/home"

framework=$(find "$root/DerivedData/SourcePackages/artifacts" -name Sparkle.framework -print -quit 2>/dev/null || true)
if [[ -z "$framework" ]]; then
    xcodebuild -resolvePackageDependencies -project "$root/DownAudible.xcodeproj" -scheme DownAudible \
        -clonedSourcePackagesDirPath "$work/Packages" > "$work/packages.log" 2>&1 || { cat "$work/packages.log" >&2; exit 1; }
    framework=$(find "$work/Packages/artifacts" -name Sparkle.framework -print -quit)
fi
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"

version=$(awk '/^MARKETING_VERSION = / { print $3 }' "$root/App.xcconfig")
build=$(awk '/^CURRENT_PROJECT_VERSION = / { print $3 }' "$root/App.xcconfig")
/usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string CaptureHelp "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string org.downaudible.help-capture "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string DownAudible "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$build" "$app/Contents/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool true "$app/Contents/Info.plist"

cp "$root/AppAssets/DownAudible.png" "$app/Contents/Resources/DownAudible.png"

mkdir "$work/cli"
touch "$work/cli/config.toml" "$work/cli/demo-account.json"
cp "$root/Scripts/Help/demo-audible-helper.py" "$work/audible-demo-helper"
chmod +x "$work/audible-demo-helper"

media="$root/DerivedData/Build/Products/Debug/DownAudible.app/Contents/Resources/MediaSupport"
mkdir "$app/Contents/Resources/MediaSupport"
for tool in ffmpeg ffprobe; do
    if [[ -x "$media/$tool" ]]; then
        executable="$media/$tool"
    else
        executable=$(command -v "$tool") || { echo "Install FFmpeg or build DownAudible to capture the media examples." >&2; exit 1; }
    fi
    ln -s "$executable" "$app/Contents/Resources/MediaSupport/$tool"
done

cat > "$work/chapters.txt" <<'METADATA'
;FFMETADATA1
title=Demo Book 3
artist=Demo Author 2
[CHAPTER]
TIMEBASE=1/1000
START=0
END=4000
title=Opening Credits
[CHAPTER]
TIMEBASE=1/1000
START=4000
END=22000
title=Chapter 1
[CHAPTER]
TIMEBASE=1/1000
START=22000
END=44000
title=Chapter 2
[CHAPTER]
TIMEBASE=1/1000
START=44000
END=46000
title=Closing Credits
METADATA
/usr/bin/python3 - "$work/tone.wav" <<'PYTHON'
from array import array
from math import pi, sin
from sys import argv
import wave

rate = 24000
second = array("h", (round(4000 * sin(2 * pi * 330 * sample / rate)) for sample in range(rate)))
with wave.open(argv[1], "wb") as output:
    output.setparams((1, 2, rate, 0, "NONE", "not compressed"))
    output.writeframes(second.tobytes() * 48)
PYTHON
/usr/bin/afconvert -f m4af -d aac -b 32000 "$work/tone.wav" "$work/tone.m4a"
"$app/Contents/Resources/MediaSupport/ffmpeg" -nostdin -v error -i "$work/tone.m4a" \
    -f ffmetadata -i "$work/chapters.txt" -map 0:a -map_metadata 1 -map_chapters 1 -c:a copy \
    "$work/Demo Audio/Demo Book 3.m4b"
mkdir -p "$work/Demo Audiobooks/m4b/Demo Author 1/Demo Book 1"
cp "$work/Demo Audio/Demo Book 3.m4b" "$work/Demo Audiobooks/m4b/Demo Author 1/Demo Book 1/Demo Book 1.m4b"
cp "$work/Demo Audio/Demo Book 3.m4b" "$work/Demo Audio/Demo Book 2.m4b"

sources=()
mkdir "$work/source"
ditto "$root/DownAudible" "$work/source/DownAudible"
ditto "$root/Scripts/Help" "$work/source/Help"
while IFS= read -r -d '' source; do
    sources+=("$source")
done < <(find "$work/source" -name '*.swift' -print0)
xcrun swiftc -whole-module-optimization -num-threads 8 -D HELP_SCREENSHOTS -target arm64-apple-macos15.0 \
    -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -F "$app/Contents/Frameworks" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${sources[@]}" -o "$app/Contents/MacOS/CaptureHelp"

CFFIXED_USER_HOME="$work/home" AUDIBLE_CONFIG_DIR="$work/cli" \
    "$app/Contents/MacOS/CaptureHelp" "$output" "$work" "$@"

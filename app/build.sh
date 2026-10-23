#!/usr/bin/env zsh
# Build Fjordhop.app and install it to ~/Applications.
#   ./build.sh          build + install + (re)launch
#   ./build.sh --no-run build + install only
#   ./build.sh --build-only  build into app/build/ only (used by the Homebrew formula)
set -euo pipefail
cd "${0:A:h}"

app="build/Fjordhop.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png "$app/Contents/Resources/"
swiftc -O -swift-version 5 -o "$app/Contents/MacOS/Fjordhop" main.swift desktops.swift
# Ad-hoc signature: enough for launching locally. Each rebuild changes the
# signature, so macOS may ask again for permission to control Ghostty.
codesign --force --sign - "$app"
[[ ${1:-} == --build-only ]] && exit 0

pkill -x Fjordhop 2>/dev/null || true
dest="$HOME/Applications/Fjordhop.app"
mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R "$app" "$dest"
echo "installed: $dest"

[[ ${1:-} == --no-run ]] || open "$dest"

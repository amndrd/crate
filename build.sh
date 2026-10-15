#!/bin/bash
# Builds Crate.app from the sources (needs Xcode Command Line Tools: xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP=Crate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macos14" -o "$APP/Contents/MacOS/Crate" Sources/*.swift
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
# Local signature, so macOS remembers the permissions you give Crate
codesign --force --sign - "$APP" >/dev/null 2>&1

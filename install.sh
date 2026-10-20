#!/bin/bash
# Installs Crate: builds the app, creates config.txt and starts Crate at every login.
# Run it again after pulling an update. Moving the folder is fine: Crate follows it.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="io.github.amndrd.crate"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
step() { printf "\033[32m›\033[0m %s\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1"; exit 1; }

bold "Installing Crate"

[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail "Crate needs macOS 14 Sonoma or later."

if ! xcrun --find swiftc >/dev/null 2>&1; then
    xcode-select --install 2>/dev/null || true
    fail "Apple's Command Line Tools are needed to build Crate. Click Install in the window that just opened, then run ./install.sh again."
fi

if ! mdfind "kMDItemCFBundleIdentifier == 'com.spotify.client'" | grep -q . && [ ! -d /Applications/Spotify.app ]; then
    printf "\033[33m! Spotify's desktop app wasn't found. Get it at https://www.spotify.com/download\033[0m\n"
fi

case "$(pwd)/" in
    "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*|"$HOME/Library/Mobile Documents/"*)
        printf "\033[33m! This folder is protected by macOS privacy settings: if macOS asks whether Crate may access it, click Allow.\n  To avoid that, move the folder to your home folder (e.g. ~/Crate) and run ./install.sh again.\033[0m\n" ;;
esac

step "Building Crate.app (about 30 seconds)…"
./build.sh

NEW_CONFIG=""
if [ ! -f config.txt ]; then
    cp config.example.txt config.txt
    NEW_CONFIG=1
    step "Created config.txt: put your playlists in it"
fi

step "Starting Crate at login…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(pwd)/Crate.app/Contents/MacOS/Crate</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/crate.log</string>
</dict>
</plist>
PLIST

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
    sleep 1
done
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || fail "Crate didn't start. Details in /tmp/crate.log"

echo
bold "✓ Crate is installed and running."
echo "  1. Put your playlists in config.txt${NEW_CONFIG:+ (opening it now)}."
echo "  2. Press ⌘ ⌥ 0 to pick a playlist (on AZERTY: ⌘ ⌥ à)."
echo "  3. The first time, allow Crate to control Spotify when macOS asks."
[ -z "$NEW_CONFIG" ] || open -a TextEdit config.txt

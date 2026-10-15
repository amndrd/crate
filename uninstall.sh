#!/bin/bash
# Stops Crate and removes everything it installed. Your config.txt stays in this folder.
set -uo pipefail
cd "$(dirname "$0")"

LABEL="io.github.amndrd.crate"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x Crate 2>/dev/null
rm -rf Crate.app "$HOME/Library/Caches/Crate"
defaults delete "$LABEL" 2>/dev/null
tccutil reset AppleEvents "$LABEL" >/dev/null 2>&1

echo "✓ Crate is uninstalled. You can now delete this folder."

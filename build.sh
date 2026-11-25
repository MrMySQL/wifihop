#!/bin/bash
# Builds WiFiHop.app, installs it to ~/Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/WiFiHop"

APP="$HOME/Applications/WiFiHop.app"
# Stop a running copy. An open dialog blocks a polite quit, so follow up with a kill.
osascript -e 'tell application id "local.wifihop" to quit' >/dev/null 2>&1 || true
pkill -f "$APP/Contents/MacOS/WiFiHop" 2>/dev/null || true
while pgrep -f "$APP/Contents/MacOS/WiFiHop" >/dev/null; do /bin/sleep 0.2; done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/WiFiHop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

open "$APP"
echo "Installed and started $APP"

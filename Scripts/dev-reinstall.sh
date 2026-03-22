#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="/Applications/OneBtnVoice.app"
APP_BUNDLE_ID="com.onebtnvoice.app"

echo "Stopping running app if needed..."
osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -x OneBtnVoice >/dev/null 2>&1 || true
sleep 0.4

echo "Rebuilding and reinstalling..."
"$ROOT_DIR/Scripts/install.sh"

echo "Launching app..."
open "$APP_PATH"

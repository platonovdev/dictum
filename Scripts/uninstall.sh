#!/bin/zsh
set -euo pipefail

APP_NAME="OneBtnVoice"
SYSTEM_APP="/Applications/$APP_NAME.app"
USER_APP="$HOME/Applications/$APP_NAME.app"

rm -rf "$SYSTEM_APP"
rm -rf "$USER_APP"

echo "$APP_NAME removed from /Applications and ~/Applications."

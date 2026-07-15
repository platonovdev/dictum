#!/bin/zsh
set -euo pipefail

APP_NAME="Dictator"
SYSTEM_APP="/Applications/$APP_NAME.app"
USER_APP="$HOME/Applications/$APP_NAME.app"

rm -rf "$SYSTEM_APP"
rm -rf "$USER_APP"
rm -rf "/Applications/Dictum.app"
rm -rf "$HOME/Applications/Dictum.app"
rm -rf "/Applications/Диктатор.app"
rm -rf "$HOME/Applications/Диктатор.app"

echo "$APP_NAME removed from /Applications and ~/Applications."

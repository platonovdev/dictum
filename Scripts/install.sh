#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Dictum"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_BUNDLE="$ROOT_DIR/.build/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
USER_APP="$HOME/Applications/$APP_NAME.app"
SIGN_IDENTITY="${DICTUM_SIGN_IDENTITY:-${ONEBTNVOICE_SIGN_IDENTITY:-}}"
SIGN_IDENTITY_NAME=""
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
  export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

if ! xcode-select -p >/dev/null 2>&1 && [[ -z "${DEVELOPER_DIR:-}" ]]; then
  echo "Xcode tools are not configured."
  exit 1
fi

echo "Building $APP_NAME..."
cd "$ROOT_DIR"
swift build -c release --product "$APP_NAME"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# SwiftPM exposes binary-target frameworks next to the executable and links
# them with @loader_path. Keep whisper.cpp there in the development bundle so
# the Metal runtime is available after installing outside Xcode.
if [[ -d "$BUILD_DIR/whisper.framework" ]]; then
  cp -R "$BUILD_DIR/whisper.framework" "$APP_BUNDLE/Contents/MacOS/"
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
find "$BUILD_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/ { print $2; exit }')"
  SIGN_IDENTITY_NAME="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '\"' '/Apple Development:/ { print $2; exit }')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  if [[ -n "$SIGN_IDENTITY_NAME" ]]; then
    echo "Signing with Apple Development identity: $SIGN_IDENTITY_NAME"
  else
    echo "Signing with Apple Development identity: $SIGN_IDENTITY"
  fi
  if ! codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_BUNDLE"; then
    echo "Apple Development signing failed."
    echo "If macOS shows a keychain access prompt, choose 'Always Allow' and run the install again."
    echo "Falling back to ad-hoc signing for this build."
    codesign --force --deep -s - "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
else
  if security find-certificate -a -c "Apple Development" -Z >/dev/null 2>&1; then
    echo "Apple Development certificate found, but no valid signing identity is available."
    echo "This usually means the certificate does not have an accessible private key."
    echo "Open Xcode > Settings > Accounts > Manage Certificates and recreate the Apple Development certificate if needed."
  else
    echo "No Apple Development signing identity found."
  fi
  echo "Falling back to ad-hoc signing."
  echo "macOS may ask for Accessibility/Input Monitoring permissions again after reinstalls."
  codesign --force --deep -s - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "Installing app bundle..."
sync_app_bundle() {
  local source_app="$1"
  local target_app="$2"

  mkdir -p "$target_app"
  rsync -a --delete "$source_app/" "$target_app/"
}

if sync_app_bundle "$APP_BUNDLE" "$DEST_APP" 2>/dev/null; then
  echo "Updated in place at $DEST_APP"
else
  mkdir -p "$HOME/Applications"
  sync_app_bundle "$APP_BUNDLE" "$USER_APP"
  echo "Updated in place at $USER_APP"
fi

echo "Launch the app and grant microphone, accessibility, and input monitoring access."

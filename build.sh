#!/bin/zsh

set -euo pipefail

readonly APP_NAME="MenuBarNetToggle"
readonly PROJECT_DIR="${0:A:h}"
readonly SOURCE_FILE="$PROJECT_DIR/main.swift"
readonly INFO_PLIST="$PROJECT_DIR/Info.plist"
readonly APP_ICON="$PROJECT_DIR/assets/AppIcon.icns"
readonly BUILD_DIR="$PROJECT_DIR/build"
readonly APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
readonly EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
readonly MODULE_CACHE="$BUILD_DIR/module-cache"
readonly SDK_ROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
readonly BUILD_ARCHITECTURE="$(/usr/bin/uname -m)"
readonly DEPLOYMENT_TARGET="13.0"
readonly SWIFT_TARGET="$BUILD_ARCHITECTURE-apple-macosx$DEPLOYMENT_TARGET"

if [[ ! -f "$SOURCE_FILE" ]]; then
  print -u2 "Source file not found: $SOURCE_FILE"
  exit 1
fi

if [[ ! -f "$INFO_PLIST" ]]; then
  print -u2 "Application property list not found: $INFO_PLIST"
  exit 1
fi

if [[ ! -f "$APP_ICON" ]]; then
  print -u2 "Application icon not found: $APP_ICON"
  exit 1
fi

/bin/rm -rf "$APP_BUNDLE" "$MODULE_CACHE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$MODULE_CACHE"

/usr/bin/swiftc \
  -O \
  -sdk "$SDK_ROOT" \
  -target "$SWIFT_TARGET" \
  -module-cache-path "$MODULE_CACHE" \
  -framework Cocoa \
  -o "$EXECUTABLE" \
  "$SOURCE_FILE"

/bin/cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
/bin/cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

print "Built and verified: $APP_BUNDLE"

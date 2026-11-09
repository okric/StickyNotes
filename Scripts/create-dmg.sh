#!/bin/bash
# Packages an already signed (and ideally stapled) .app into the styled DMG.
#
#   Scripts/create-dmg.sh build/StickyNotes.app build
#
# Kept separate from build-app.sh so a DMG can be rebuilt from a finished,
# notarized app without re-submitting it to Apple.

set -euo pipefail

APP_DIR="${1:?usage: create-dmg.sh <App.app> <output-dir>}"
BUILD_DIR="${2:?usage: create-dmg.sh <App.app> <output-dir>}"
APP_NAME="$(basename "$APP_DIR" .app)"
VOL_NAME="${DMG_VOLUME_NAME:-MD Sticky Notes}"

DMG_TMP="$BUILD_DIR/tmp.dmg"
DMG_PATH="$BUILD_DIR/MD$APP_NAME.dmg"
DMG_DIR="$BUILD_DIR/dmg"
rm -rf "$DMG_DIR" "$DMG_PATH" "$DMG_TMP"
mkdir -p "$DMG_DIR"
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# Create read-write DMG first (for styling)
hdiutil create -volname "$VOL_NAME" -srcfolder "$DMG_DIR" -ov -format UDRW "$DMG_TMP" >/dev/null
rm -rf "$DMG_DIR"

# Mount and style with AppleScript
MOUNT_DIR="/Volumes/$VOL_NAME"
hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen >/dev/null
sleep 3

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 400, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "$APP_NAME.app" of container window to {150, 80}
        set position of item "Applications" of container window to {150, 260}
        close
        open
    end tell
end tell
APPLESCRIPT

# Wait for Finder to apply changes
sleep 2
sync

# Unmount
hdiutil detach "$MOUNT_DIR" >/dev/null
# Mounting the DMG registers its copy; drop it so Finder keeps one entry.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREGISTER" -u "$MOUNT_DIR/$APP_NAME.app" >/dev/null 2>&1 || true

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TMP" -format UDZO -o "$DMG_PATH" >/dev/null
rm -f "$DMG_TMP"
echo "✅ DMG created at: $DMG_PATH"

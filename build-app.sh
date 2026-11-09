#!/bin/bash

# Builds the app with xcodebuild and packages a styled DMG.
#
#   ./build-app.sh                                  # ad-hoc signed
#   CODESIGN_IDENTITY="Developer ID Application: …" ./build-app.sh
#   CODESIGN_IDENTITY="Developer ID Application: …" \
#     NOTARY_PROFILE=MDStickyNotes ./build-app.sh     # signed + notarized + stapled
#
# The CodeMirror bundle is built by the Xcode pre-build phase
# (Scripts/build-editor.sh); no separate npm step is needed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="StickyNotes"
BUILD_DIR="$ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
XCODEPROJ="$ROOT/$APP_NAME.xcodeproj"

# Regenerate the project when the spec or the file list changed.
needs_regen() {
    [ ! -d "$XCODEPROJ" ] && return 0
    [ "$ROOT/project.yml" -nt "$XCODEPROJ/project.pbxproj" ] && return 0
    [ -n "$(find "$ROOT/Sources" -newer "$XCODEPROJ/project.pbxproj" -name '*.swift' -print -quit)" ]
}

if needs_regen; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "error: xcodegen not found (brew install xcodegen)" >&2
        exit 1
    fi
    xcodegen generate >/dev/null
fi

XCODE_ARGS=(
    -project "$XCODEPROJ"
    -scheme "$APP_NAME"
    -configuration Release
    -derivedDataPath "$DERIVED"
    build
)

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "Building with Developer ID signing..."
    XCODE_ARGS+=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY"
        ENABLE_HARDENED_RUNTIME=YES
        OTHER_CODE_SIGN_FLAGS="--timestamp"
        # Xcode otherwise injects com.apple.security.get-task-allow, which has
        # no business in a distribution build.
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    )
else
    echo "Building ad-hoc signed app..."
fi

xcodebuild "${XCODE_ARGS[@]}" | tail -5

rm -rf "$APP_DIR"
cp -R "$DERIVED/Build/Products/Release/$APP_NAME.app" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# Notarize the app before the DMG is built so the stapled ticket travels
# inside it. Requires a Developer ID signature and a stored notarytool profile:
#   xcrun notarytool store-credentials "MDStickyNotes" \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${CODESIGN_IDENTITY:-}" ]; then
        echo "error: NOTARY_PROFILE requires CODESIGN_IDENTITY (Developer ID)" >&2
        exit 1
    fi
    echo "Notarizing (profile: $NOTARY_PROFILE)..."
    ZIP="$BUILD_DIR/$APP_NAME.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    # Hard gate: never ship a build Gatekeeper rejects.
    spctl -a -t exec -vv "$APP_DIR"
fi

# Point Finder's "Open With > Sticky Notes" at this copy. xcodebuild registers
# its DerivedData build; leaving both registered duplicates the entry.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREGISTER" -u "$DERIVED/Build/Products/Release/$APP_NAME.app" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")
echo "✅ $APP_NAME.app $VERSION built at: $APP_DIR"

# Create styled DMG for distribution
echo "Creating DMG..."
DMG_TMP="$BUILD_DIR/tmp.dmg"
DMG_PATH="$BUILD_DIR/MDStickyNotes.dmg"
VOL_NAME="MD Sticky Notes"
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
        set position of item "StickyNotes.app" of container window to {150, 80}
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
"$LSREGISTER" -u "$MOUNT_DIR/StickyNotes.app" >/dev/null 2>&1 || true

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TMP" -format UDZO -o "$DMG_PATH" >/dev/null
rm -f "$DMG_TMP"
echo "✅ DMG created at: $DMG_PATH"

echo "To run: open $APP_DIR"

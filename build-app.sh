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

APP_NAME="Sticky Notes"
PROJECT_NAME="StickyNotes"
BUILD_DIR="$ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
XCODEPROJ="$ROOT/$PROJECT_NAME.xcodeproj"

# Regenerate the project when the spec or the file list changed.
needs_regen() {
    [ ! -d "$XCODEPROJ" ] && return 0
    [ "$ROOT/project.yml" -nt "$XCODEPROJ/project.pbxproj" ] && return 0
    [ -n "$(find "$ROOT/Sources" -newer "$XCODEPROJ/project.pbxproj" -name '*.swift' -print -quit)" ]
}

if needs_regen; then
    XCODEGEN_BIN="$(command -v xcodegen || true)"
    if [ -z "$XCODEGEN_BIN" ] && [ -x /opt/homebrew/bin/xcodegen ]; then
        XCODEGEN_BIN=/opt/homebrew/bin/xcodegen
    fi
    if [ -z "$XCODEGEN_BIN" ]; then
        echo "error: xcodegen not found (brew install xcodegen)" >&2
        exit 1
    fi
    "$XCODEGEN_BIN" generate >/dev/null
fi

# Build the editor bundle before Xcode starts. The pre-build phase can run
# after the resource copy in practice, which leaves the app one bundle behind.
"$ROOT/Scripts/build-editor.sh"

XCODE_ARGS=(
    -project "$XCODEPROJ"
    -scheme "$PROJECT_NAME"
    -configuration Release
    -derivedDataPath "$DERIVED"
    # A user-level SYMROOT preference can otherwise redirect products away
    # from $DERIVED, and the copy below fails. Pin it to derived data.
    SYMROOT="$DERIVED/Build/Products"
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
#   xcrun notarytool store-credentials "okric-notary"
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

# Create styled DMG for distribution (from the signed/stapled app)
echo "Creating DMG..."
"$ROOT/Scripts/create-dmg.sh" "$APP_DIR" "$BUILD_DIR"

echo "To run: open $APP_DIR"

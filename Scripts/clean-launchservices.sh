#!/bin/bash
# Removes duplicate "Sticky Notes" entries from Finder / Launchpad by
# unregistering every copy from Launch Services except one.
#
#   Scripts/clean-launchservices.sh                  keep /Applications copy, else build/Sticky Notes.app
#   Scripts/clean-launchservices.sh <path/to.app>    keep that copy
#   Scripts/clean-launchservices.sh --purge          also delete stale build products
#
# Every copy keeps its own Launch Services record, so a Debug build, a Release
# build, a DerivedData build and a mounted DMG all show up as separate apps.
# Unregistering only drops the record; the bundle on disk is untouched.
#
# A running app re-registers itself, and so does xcodebuild, so quit the stale
# copies (or use --purge) or the entries come back.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Sticky Notes"
PROJECT_NAME="StickyNotes"
BUNDLE_ID="com.mdstickynotes"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

PURGE=0
KEEP=""
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -*) echo "error: unknown option $arg" >&2; exit 1 ;;
        *) KEEP="$arg" ;;
    esac
done

if [ -z "$KEEP" ]; then
    if [ -d "/Applications/$APP_NAME.app" ]; then
        KEEP="/Applications/$APP_NAME.app"
    elif [ -d "$ROOT/build/$APP_NAME.app" ]; then
        KEEP="$ROOT/build/$APP_NAME.app"
    fi
fi

if [ "$PURGE" -eq 1 ]; then
    # xcodebuild's DerivedData and the intermediate build products are the
    # usual duplicates. The packaged app in build/ and any DMG stay.
    for dir in \
        "$ROOT/build/DerivedData/Build/Products/Debug" \
        "$ROOT/build/DerivedData/Build/Products/Release" \
        "$HOME/Library/Developer/Xcode/DerivedData/${PROJECT_NAME}-"*; do
        [ -e "$dir" ] || continue
        rm -rf "$dir"
        echo "removed:      $dir"
    done
fi

# Launch Services keeps records for bundles that no longer exist (ejected
# DMGs, deleted DerivedData), so the dump is the source of truth here.
REGISTERED=()
while IFS= read -r line; do
    REGISTERED+=("$line")
done < <(
    "$LSREGISTER" -dump 2>/dev/null \
        | sed -n 's/^path: *//p' \
        | sed -E 's/ \(0x[0-9a-f]+\)$//' \
        | grep -F "/$APP_NAME.app" \
        | sort -u
)

kept=0
removed=0
for path in "${REGISTERED[@]}"; do
    # Guard against unregistering an unrelated bundle that happens to share
    # the name: only act on copies that claim our bundle identifier (or that
    # no longer exist, which is always a stale record).
    if [ -f "$path/Contents/Info.plist" ]; then
        id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$path/Contents/Info.plist" 2>/dev/null || true)
        [ "$id" = "$BUNDLE_ID" ] || continue
    fi

    if [ -n "$KEEP" ] && [ "$path" = "$KEEP" ]; then
        echo "keep:         $path"
        kept=1
        continue
    fi

    if "$LSREGISTER" -u "$path" >/dev/null 2>&1; then
        echo "unregistered: $path"
        removed=$((removed + 1))
    else
        echo "could not unregister: $path" >&2
    fi
done

if [ "$kept" -eq 0 ]; then
    echo "note: no kept copy found${KEEP:+ ($KEEP)}; run ./build-app.sh to package one" >&2
fi
echo "unregistered $removed copies of $APP_NAME.app"

if pgrep -qf "$APP_NAME.app/Contents/MacOS/$APP_NAME"; then
    echo "warning: a Sticky Notes instance is running and will re-register itself; quit it and re-run" >&2
fi

#!/bin/bash
# Builds the CodeMirror editor bundle into Resources/Editor/.
# Used as an Xcode pre-build phase and safe to run by hand.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/editor-web"
OUT="$ROOT/Sources/StickyNotes/Resources/Editor/editor.bundle.js"

# Rebuild only when inputs are newer than the bundle.
needs_build() {
    [ ! -f "$OUT" ] && return 0
    [ -n "$(find "$SRC/src" "$SRC/package.json" "$SRC/package-lock.json" \
        -newer "$OUT" -print -quit 2>/dev/null)" ]
}

if ! needs_build; then
    exit 0
fi

# Xcode build phases do not inherit the login shell PATH; look for nvm installs.
if ! command -v npm >/dev/null 2>&1; then
    for d in "$HOME"/.nvm/versions/node/*/bin; do
        if [ -x "$d/npm" ]; then
            export PATH="$d:$PATH"
        fi
    done
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "error: npm not found. Install Node.js 18+ (or add it to PATH) and rebuild." >&2
    exit 1
fi

cd "$SRC"
if [ ! -d node_modules ]; then
    npm ci
fi
npm run build
cp dist/editor.bundle.js "$OUT"
echo "Built editor bundle: $OUT"

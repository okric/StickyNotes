# MD Sticky Notes

A native macOS sticky note app with Obsidian-style markdown live preview, built with Swift and CodeMirror 6.

> **Fork notice** — This is a fork of [jaesuny/markdown-sticky-notes](https://github.com/jaesuny/markdown-sticky-notes)
> by Jaesun Park, maintained by [okric](https://github.com/okric). It is MIT licensed; the
> original copyright notice is preserved verbatim in [LICENSE](LICENSE). Changes relative to
> upstream are documented in [CHANGELOG.md](CHANGELOG.md) and summarized under
> [Changes in this fork](#changes-in-this-fork).

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)

## Features

### Markdown Editor
- **Live Preview**: Obsidian-style WYSIWYG editing with instant rendering
- **GFM Support**: Tables, strikethrough, task lists, and more
- **Syntax Highlighting**: 15+ programming languages in code blocks
- **Math Rendering**: KaTeX support for inline (`$...$`) and block (`$$...$$`) equations

### Sticky Note Experience
- **Plain Markdown files**: every note is a `.md` file in a folder you choose (Obsidian vaults work)
- **Fixed filename line**: every note shows its filename (without `.md`) above the body, in a font chosen in Settings; it is not part of the Markdown and cannot be edited or removed
- **Note stacks**: notes added to the notes folder pile into the default stack — one window with the front sheet on top, the sheets underneath showing at its edge
  - Hover the stack for the chevrons: they cycle the front sheet in creation order
  - Hold ⌥ and drag the stack to pull the front note out into a normal window
  - Put a placed note back by dragging it onto the stack, or use File > Move Note to Stack
  - The stack keeps its own size while switching sheets; closing it trashes the front note and reveals the next
  - Stack membership is metadata only; the `.md` file is identical to any other note
- **Floating Windows**: Always visible while you work
- **Multi-Display**: notes remember their monitor and position across reused and resized displays
- **Pin on Top**: Keep important notes above all windows (Cmd+Shift+P)
- **Multiple Colors**: Yellow, pink, blue, green, purple, orange
- **Adjustable Opacity**: Transparency slider for each note
- **Auto-Save**: Edits are written straight back to the file
- **Open With**: open any `.md` file from Finder (or `open -a "Sticky Notes" note.md`); it is edited in place, wherever it lives
- **Folder is the source of truth**: top-level `.md` files in the notes folder open as stickies at launch; drop a file in and relaunch
- **Live folder sync**: files added, deleted or edited in the notes folder update the stickies without a relaunch (an open note keeps your text if you have unsaved keystrokes)
- **Close moves to Trash**: closing a sticky moves its `.md` to the Trash, where you can restore it
- **Remote Notes**: File > Open Note URL… (Cmd+Shift+O) opens a shared Notes link (`…/n/<id>`) as a sticky; add a `notes`-scope token in Settings to edit it (read-only without one)
- **Fonts**: pick the note body and filename fonts in Settings; sizes stay fixed
- **Notes Folder Settings**: pick any folder, or create `~/Documents/Sticky Notes` (Cmd+,)

### Keyboard Shortcuts
| Shortcut | Action |
|----------|--------|
| Cmd+N | New note |
| Cmd+O | Open Markdown files |
| Cmd+Shift+O | Open note URL |
| Cmd+Shift+P | Pin on top |
| Cmd+B / I / K | Bold / Italic / Link |
| Cmd+F | Find in note |
| Cmd+Shift+F | Find and replace |
| Cmd+` | Cycle through notes |

## Installation

### Build from Source (Recommended)
```bash
# Prerequisites: macOS 12+, Swift 5.9+, Node.js 18+

# Clone and build
git clone https://github.com/okric/StickyNotes.git
cd StickyNotes
cd editor-web && npm ci && cd ..
./build-app.sh

# Run
open "build/Sticky Notes.app"
```

### Prebuilt DMG
Prebuilt releases are published on the
[releases page](https://github.com/okric/StickyNotes/releases). Builds are
Developer ID signed, notarized, and stapled when released from this fork.

> The upstream Homebrew cask (`brew install --cask md-sticky-notes`) installs
> the *upstream* app, not this fork.

## Demo

https://github.com/user-attachments/assets/c3dce235-9c50-4cee-832d-267e0e5f8024

## Screenshots

<img src="assets/screenshot.png" alt="MD Sticky Notes" width="360">

## Changes in this fork

Security hardening on top of upstream v1.1.0 (no feature changes):

- **Link scheme allowlist** — only `http`, `https` and `mailto` links are opened.
  Previously `file://`, `smb://` and arbitrary third-party URL schemes reached
  `NSWorkspace.open` from note content.
- **No script interpolation** — note values are passed to the WebView as
  `callAsyncJavaScript` arguments instead of being spliced into script source.
- **Web Inspector off in release** — `developerExtrasEnabled` removed.
- **Version/build numbers from one variable** in `build-app.sh`, matching the
  released tag (`1.0.0` vs `v1.1.0` drift fixed).
- **Developer ID signing supported** — `CODESIGN_IDENTITY=... ./build-app.sh`
  signs with the hardened runtime; ad-hoc remains the default for local builds.

Known limitations that remain (upstream behavior): notes are stored unencrypted
in `UserDefaults`, and the app is not sandboxed.

## Where notes are stored

Notes are **not** kept in a database or `UserDefaults`:

```
~/Documents/Sticky Notes/          # default folder for new notes (configurable)
├── Welcome.md
└── Note 2026-11-08 143012.md

~/Library/Application Support/com.mdstickynotes/
├── index.json                     # per-note metadata: path, window frame, color, cursor, stack membership
├── stack.json                     # default stack position and front sheet
├── settings.json                  # chosen notes folder, migration flag
└── remote/                        # cached bodies of Notes API notes (read-only)
```

- The index stores only presentation metadata — never note bodies.
- Stack membership is an index field (`stackID`); the Markdown file has no stack
  marker and opens the same way whether it is in the stack or on its own.
- Edits are written to the `.md` file after a 500 ms debounce, atomically.
- Closing a note window moves its Markdown file to the **Trash**; restore it
  from there. Remote notes are only unlinked. Any top-level `.md` file in the
  notes folder that isn't open reopens as a sticky at the next launch
  (subfolders are not scanned).
- Finder "Open With" and `open -a "Sticky Notes" file.md` add a note for that file
  in place; the file is never copied into the notes folder.
- Files added, deleted or changed in the notes folder are picked up live through
  an FSEvents watcher. An open note with unsaved keystrokes keeps its text; the
  external change is skipped until the next pass.
- Notes created by the upstream version (stored in `UserDefaults`) are exported
  to the notes folder on first launch, once.

## Technical Details

### Architecture
- **Swift/SwiftUI**: Native macOS app shell with NSPanel windows
- **WKWebView + CodeMirror 6**: High-performance markdown editor
- **KaTeX**: Fast LaTeX math rendering
- **Hybrid Approach**: Native performance with battle-tested web editor

### Why Hybrid?
- Pure native markdown editors require months of TextKit work
- Electron is too resource-heavy
- WKWebView is built into macOS with zero external dependencies
- CodeMirror 6 is the most advanced web editor available

## Development

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). `StickyNotes.xcodeproj` is committed, so you can open it directly;
regenerate after editing `project.yml`:

```bash
xcodegen generate
open StickyNotes.xcodeproj
```

```bash
# Full build + DMG from the command line
./build-app.sh && open "build/Sticky Notes.app"

# JS-only fast iteration (Xcode pre-build phase rebuilds the bundle when
# editor-web/src changed; this manual path skips the full app rebuild)
cd editor-web && npm run build && \
  cp dist/editor.bundle.js ../"build/Sticky Notes.app/Contents/Resources/Editor/" && \
  open "../build/Sticky Notes.app"
```

### Releasing

```bash
# Signed, notarized, stapled app + DMG
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE=okric-notary ./build-app.sh
```

Without `NOTARY_PROFILE` the build is signed but not notarized, which is fine
for local use. Gatekeeper must accept the app before publishing:
`spctl -a -t exec -vv "build/Sticky Notes.app"`.

`xcodebuild` and every Debug/Release/DerivedData copy registers itself with
Launch Services, which shows up as several "Sticky Notes" apps in Finder and
Launchpad. Prune them with:

```bash
./Scripts/clean-launchservices.sh --purge
```

Running copies re-register themselves, so quit stale instances first.

## License

MIT

## Credits

- Original project: [jaesuny/markdown-sticky-notes](https://github.com/jaesuny/markdown-sticky-notes), © 2025 Jaesun Park (MIT)
- Built with [Claude Code](https://claude.ai/code)
- Editor powered by [CodeMirror 6](https://codemirror.net/)
- Math rendering by [KaTeX](https://katex.org/)

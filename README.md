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
- **Floating Windows**: Always visible while you work
- **Pin on Top**: Keep important notes above all windows (Cmd+Shift+P)
- **Multiple Colors**: Yellow, pink, blue, green, purple, orange
- **Adjustable Opacity**: Transparency slider for each note
- **Auto-Save**: Edits are written straight back to the file
- **Notes Folder Settings**: pick any folder, or create `~/Documents/Sticky Notes` (Cmd+,)

### Keyboard Shortcuts
| Shortcut | Action |
|----------|--------|
| Cmd+N | New note |
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
open build/StickyNotes.app
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
├── index.json                     # per-note metadata: path, window frame, color, cursor
└── settings.json                  # chosen notes folder, migration flag
```

- The index stores only presentation metadata — never note bodies.
- Edits are written to the `.md` file after a 500 ms debounce, atomically.
- Closing a note window removes it from the app but **keeps the file**.
- Files changed externally are picked up the next time the app launches.
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
./build-app.sh && open build/StickyNotes.app

# JS-only fast iteration (Xcode pre-build phase rebuilds the bundle when
# editor-web/src changed; this manual path skips the full app rebuild)
cd editor-web && npm run build && \
  cp dist/editor.bundle.js ../build/StickyNotes.app/Contents/Resources/Editor/ && \
  open ../build/StickyNotes.app
```

## License

MIT

## Credits

- Original project: [jaesuny/markdown-sticky-notes](https://github.com/jaesuny/markdown-sticky-notes), © 2025 Jaesun Park (MIT)
- Built with [Claude Code](https://claude.ai/code)
- Editor powered by [CodeMirror 6](https://codemirror.net/)
- Math rendering by [KaTeX](https://katex.org/)

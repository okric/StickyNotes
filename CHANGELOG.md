# Changelog

All notable changes to MD Sticky Notes will be documented in this file.

## [1.3.2] - 2026-11-08

### The app is named “Sticky Notes”

- The bundle, executable and Finder/Dock name use a space: `Sticky Notes.app`
- The bundle identifier stays `com.mdstickynotes`, so notes and settings carry over
- `build-app.sh`, the DMG and the Launch Services cleanup script follow the new
  name; the DMG is still `MDStickyNotes.dmg`

### Closing a note moves it to the Trash

- Closing a sticky asks once, then moves its `.md` to the system Trash instead
  of leaving it in the folder
- Recovery is the Trash itself: no in-app undo, no extra UI
- Remote notes keep their server copy; only the local link and cache are removed
- Quitting the app never trashes notes; they reopen on the next launch

### Live notes folder sync

- The notes folder is watched with FSEvents while the app runs
- A `.md` dropped into the folder opens as a sticky without a relaunch; deleting
  a file closes its sticky (nothing is trashed — the file is already gone)
- Bodies edited in another editor reload into the open sticky when it is idle; a
  note with unsaved keystrokes keeps the user's text and is skipped
- Changing the notes folder in Settings re-watches it and syncs the new folder
- All passes stay top-level only; subfolders are never scanned

## [1.3.1] - 2026-11-08

### Notes folder is scanned at launch

- Every top-level Markdown file in the notes folder now opens as a sticky on
  launch, even when it was never opened by the app (drop a `.md` in, relaunch)
- Closing a sticky kept its file in this release; 1.3.2 moves it to the Trash
- Subfolders are not scanned (the folder may be a whole Obsidian vault)
- A welcome note is only created when the index *and* the notes folder are empty

## [1.3.0] - 2026-11-08

### App icon and notarized releases (fork)

- Bundle an app icon (`AppIcon.icns`) via `CFBundleIconFile`
- `build-app.sh` accepts `NOTARY_PROFILE` to notarize, staple and Gatekeeper-check
  the signed app before the DMG is created
- DMG packaging moved to `Scripts/create-dmg.sh` so it can be rebuilt from a
  finished app without re-submitting to Apple
- `Scripts/clean-launchservices.sh` removes duplicate "Sticky Notes" entries
  from Finder / Launchpad left by Debug, DerivedData and DMG copies
- Version bumped to 1.3.0 (build 10300)

### Remote notes (fork)

- File > Open Note URL… (Cmd+Shift+O) or `open -a StickyNotes https://…/n/<id>`
  opens a note shared by a Notes server as a sticky
- Body, title and `revision` come from the open `GET /api/shared/<shareId>`
  endpoint; no token needed
- The body is cached in `~/Library/Application Support/com.mdstickynotes/remote/`
  so the note opens offline, and refetched every 5 seconds
- Read-only until a `notes`-scope token is saved in Settings (Cmd+,); the token
  lives in the macOS Keychain, never in the settings files
- Edits are debounced and sent as `PATCH /api/notes/:id` with `If-Match`;
  a `409` offers "Reload Theirs" or "Keep Mine" instead of overwriting

### Multi-display windows (fork)

- Notes remember the display they are on (UUID) and their offset on it, so they
  reopen on the same monitor after the arrangement, resolution or scale changes
- Fixed a note that lived on a secondary display reopening on the main screen:
  `NSWindow` clamps a fully off-main rect at init, so the position is applied
  once the window exists
- Titlebar dragging moves the window by the pointer delta in global points, so
  crossing displays (including negative origins and mixed 1x/2x scaling) no
  longer re-anchors or jumps; AppKit's frame constraint is disabled for note
  panels (restore clamps instead)
- Startup preview renders Markdown with the editor's type scale (headings,
  lists, code, quotes, inline styles) instead of raw source, so unfocused notes
  no longer look smaller than they do once clicked
- Pre-rendered snapshots are captured at each note window's own size. The shared
  WebView lives in the active window, so snapshots used to be aspect-fitted into
  smaller windows, shrinking their text until the note was clicked

### Open Markdown files from Finder (fork)

- **File > Open… (Cmd+O)** picks one or more Markdown files anywhere on disk
- The app registers as an alternate handler for Markdown (`net.daringfireball.markdown`:
  `.md`, `.markdown`, `.mdown`, `.mkdn`, `.mkd`, `.mdwn`), so "Open With >
  Sticky Notes" and `open -a StickyNotes note.md` work
- Files are edited in place — nothing is copied or moved, so notes can live
  anywhere on disk (Obsidian vaults, Desktop, external volumes)
- Opening a file that already has an open note re-reads it from disk and brings
  its window forward instead of creating a duplicate
- `build-app.sh` registers the packaged copy with Launch Services and drops the
  DerivedData registration, so Finder lists one app instead of several

---

## [1.2.0] - 2026-11-08

### Notes storage (fork)

- Notes are now external Markdown files; the app stores only the path and
  presentation metadata in `~/Library/Application Support/com.mdstickynotes/index.json`
- Settings window (Cmd+,) with a folder picker and a one-click
  "Create Folder in Documents" action
- Edits are written back to the file (atomic, 500 ms debounce); closing a window
  keeps the file on disk
- One-time migration of notes from the old `UserDefaults` storage
- Xcode project generated from `project.yml`; `build-app.sh` now drives `xcodebuild`

---

## [1.1.1] - 2026-11-08

### Security (fork)

- Restrict `openURL` bridge to `http`/`https`/`mailto`; drop `file://`, `smb://`
  and custom schemes from note links
- Pass note values to the WebView via `callAsyncJavaScript` arguments instead of
  string interpolation into `evaluateJavaScript`
- Disable `developerExtrasEnabled` in release builds
- Single-source version and build numbers in `build-app.sh` (released DMG said
  `1.0.0` while tagged `v1.1.0`)
- Optional Developer ID signing with hardened runtime via `CODESIGN_IDENTITY`

---

## [1.0.0] - 2025-02-07

### Initial Release

#### Markdown Editor
- CodeMirror 6 professional editor with Obsidian-style live preview
- GFM (GitHub Flavored Markdown) support
  - Tables with proper alignment
  - Strikethrough (`~~text~~`)
  - Task lists (`- [ ]` / `- [x]`)
- Syntax highlighting for 15+ languages (JavaScript, Python, Swift, Go, Rust, etc.)
- KaTeX math rendering
  - Inline math: `$E = mc^2$`
  - Block math: `$$\int_0^\infty e^{-x^2} dx$$`
- Cursor unfold pattern (Obsidian-style): edit source when cursor is inside

#### Sticky Note Features
- Floating NSPanel windows that stay visible
- Pin on Top mode (Cmd+Shift+P) for always-on-top
- 6 pastel color themes: yellow, pink, blue, green, purple, orange
- Adjustable opacity with titlebar slider
- Auto-save with debouncing
- Window state persistence (position, size, opacity, color)
- Cursor and scroll position restoration

#### Keyboard Shortcuts
- Cmd+N: New note
- Cmd+Shift+P: Toggle pin on top
- Cmd+B: Bold
- Cmd+I: Italic
- Cmd+K: Insert link
- Cmd+E: Inline code
- Cmd+F: Find in note
- Cmd+Shift+F: Find and replace
- Cmd+`: Cycle through notes
- Cmd+click: Open links in browser

#### Technical
- Native macOS app (Swift/SwiftUI + AppKit)
- WKWebView-based editor with Swift-JavaScript bridge
- Single webpack bundle (~2.5MB with KaTeX fonts)
- macOS 12+ (Monterey) support

---

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format.

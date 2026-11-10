# Future work

Known limitations of the current build and the work they imply. Ordered by how
likely they are to bite a user next, not by effort.

## Notes that live outside the app's folder

Shipped: Finder "Open With", `open -a "Sticky Notes" note.md`, drag onto the Dock
icon, and `application(_:open:)` while the app runs. Files are edited in place;
nothing is copied into the notes folder.

Open items:

- **Sandboxing would break this.** The app is not sandboxed, which is the only
  reason it can read and write arbitrary paths. If it is ever sandboxed (App
  Store), add `com.apple.security.files.user-selected.read-write`, store a
  security-scoped bookmark per note, and call
  `startAccessingSecurityScopedResource` on load / `stopAccessing…` on close.
  Without bookmarks, notes outside the notes folder stop saving after a
  relaunch.
- **TCC prompts.** The first open of a file under Desktop, Documents,
  Downloads or iCloud Drive triggers the macOS consent prompt. Ad-hoc signed
  rebuilds can prompt again; a Developer ID signature keeps the grant stable.
  Document this in the README before the next release.
- **iCloud / OneDrive placeholders.** A file evicted to the cloud fails
  `String(contentsOf:)` and is shown as an empty missing note. Before reading,
  check `ubiquitousItemDownloadingStatusKey` and call
  `startDownloadingUbiquitousItem`, or use `NSFileCoordinator` and wait.
- **Read-only volumes and network shares.** Opening succeeds; the first save
  fails. `NoteManager` only logs the error. Surface a "could not save" state in
  the note window and keep edits in memory instead of dropping them.
- **External changes while a note is open.** Shipped in 1.3.2: the notes folder
  is watched with FSEvents and an edited file reloads into its sticky when no
  local keystrokes are pending. Still open: an edit made while the sticky has
  unsaved text is deferred, not merged — no conflict prompt exists.
- **Duplicate apps in Finder / Launchpad.** Every registered copy (Debug,
  Release, DerivedData, mounted DMG) shows up as its own "Sticky Notes". Run
  `Scripts/clean-launchservices.sh --purge` after building; a running copy
  re-registers itself, so quit stale instances first. Launchpad can need a
  relaunch of the Dock to refresh its cache.

## Note stacks

Shipped: one default stack. Files that appear in the notes folder from outside
join it, while Cmd+N creates a placed note. The stack window shows the front
sheet with the sheets underneath peeking out, a count badge, hover chevrons
(newest first), and ⌥-drag to pull the front note into its own window. A placed
note rejoins by dragging it onto the stack or with File > Move Note to Stack.
The close button trashes the front sheet and reveals the next one. Membership
is an index field only; `.md` files are untouched.

Open items:

- **Only one stack exists.** `Note.stackID` is a string and `stack.json` holds
  one record, so named/multiple stacks can be added without changing the file
  format.
- The stack keeps its own size while switching sheets; member notes keep their
  old `size` values until they are pulled out (the pull-out uses the stack's
  current size).
- Font choices are a curated list, not every installed family; sizes are fixed
  (body 14, title 15). Renaming the file still does not rename the title or
  write a heading back to the Markdown.

## Remote notes (Notes API)

Shipped: File > Open Note URL… (Cmd+Shift+O) or
`open -a "Sticky Notes" https://notes.example.com/n/<id>`. The app fetches
`GET /api/shared/<shareId>` (open, no token), caches the body in
`Application Support/com.mdstickynotes/remote/`, polls every 5 seconds, and
edits through `PATCH /api/notes/:id` with `If-Match` when a `notes`-scope token
is saved in Settings (Keychain). A 409 offers reload/overwrite.

Still to do:

- create a note from a sticky (`POST /api/notes`)
- batch edits / an offline outbox (one request per note today)
- token pairing flow (tokens are still minted on the server)
- cheaper polling (`GET /api/notes` returns every body and `html`, no
  `since`/`fields`)

A URL only exists for **shared** notes (public read-only link); an authenticated
open-by-id link does not exist by design.

The full proposal lives next to the Notes service:
`~/Projects/Notes/.work/PLAN-sticky-client.md`.

## Release pipeline

- **Notarization** uses the `okric-notary` notarytool keychain profile. The app
  builds signed with the Developer ID identity, and `build-app.sh` notarizes,
  staples and Gatekeeper-checks when `NOTARY_PROFILE` is set:

  ```bash
  CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
    NOTARY_PROFILE=okric-notary ./build-app.sh
  ```
- **Publish steps** are still manual: tag, `gh release create`, upload
  `build/MDStickyNotes.dmg`, then verify the app extracted from the downloaded
  DMG with `spctl -a -t exec -vv` (never assess the staged copy).
- **Sparkle 2 auto-updates** are not wired: needs `SUFeedURL`,
  `SUPublicEDKey`, an appcast per release, and an Ed25519 key pair. Follow
  `~/Projects/Wiki/how-to/notarized-distribution-and-sparkle-updates.md`.
- **Version/build numbers** are single-sourced in `project.yml`
  (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). Bump both per release;
  Sparkle compares `CFBundleVersion` (currently `major*10000+minor*100+patch`).

## Editor and notes

- Rename the backing file when the first heading changes (title is the file
  name at creation).
- Relink a note whose file was moved or deleted (`isMissing` has no UI yet;
  typing recreates the file at the old path).
- Remote note sources, see above.
- The editor still writes UTF-8 only; a non-UTF-8 Markdown file fails to open
  from Finder with a log line and a beep.

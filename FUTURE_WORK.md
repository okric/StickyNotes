# Future work

Known limitations of the current build and the work they imply. Ordered by how
likely they are to bite a user next, not by effort.

## Notes that live outside the app's folder

Shipped: Finder "Open With", `open -a StickyNotes note.md`, drag onto the Dock
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
- **External changes while a note is open.** The file is re-read at launch and
  when a file is opened from Finder, but an edit made in Obsidian while the
  sticky is open is overwritten by the next autosave. Watch the file
  (`DispatchSourceFileSystemObject` or `FSEventStream`) and either reload or
  ask which copy wins.
- **Duplicate apps in Finder / Launchpad.** Every registered copy (Debug,
  Release, DerivedData, mounted DMG) shows up as its own "Sticky Notes". Run
  `Scripts/clean-launchservices.sh --purge` after building; a running copy
  re-registers itself, so quit stale instances first. Launchpad can need a
  relaunch of the Dock to refresh its cache.

## Remote notes (Notes API)

`NoteSourceKind.remoteURL` exists in the model and decodes, but nothing creates
or reads it. The Notes service (`https://notes.example.com`, LAN
`http://192.168.1.44:8094`) can be used today only as one-way capture: a
`write`-scope token can `POST /api/notes`, nothing else.

Not usable as-is for a two-way sticky because:

- no per-note URL to "open" (the SPA has no routing);
- no incremental sync (`GET /api/notes` returns every body and rendered HTML);
- no optimistic concurrency (PATCH is unconditional last-write-wins);
- no read+edit scope for a third-party client (write = create only);
- no token pairing flow for a desktop app (tokens are minted by hand on the
  server).

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

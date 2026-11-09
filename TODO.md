# TODO

## Release pipeline

- [ ] Wire signed + notarized releases (not started; `build-app.sh` still
      defaults to ad-hoc signing, but now drives `xcodebuild`).
      - `build-app.sh` already accepts `CODESIGN_IDENTITY` and enables the
        hardened runtime; add notarize/staple/`spctl` steps around it.
      - Follow `~/Projects/Wiki/how-to/notarized-distribution-and-sparkle-updates.md`
        and `~/Projects/Wiki/how-to/creating-styled-macos-release-dmg.md`.
      - Hard requirement: never upload a build that `spctl -a -t exec` rejects.
      - Verify the app extracted from the published DMG, not the staged copy.
- [ ] Decide whether to add Sparkle 2 auto-updates (needs `SUFeedURL`,
      `SUPublicEDKey`, appcast per release).

## Decisions

- Bundle identifier stays `com.mdstickynotes` (drop-in replacement; the fork and
  upstream are not meant to be installed side by side — they would share the
  same `UserDefaults` domain and clobber each other's notes).
- Note bodies live in external Markdown files; only metadata is indexed in
  Application Support. Remote URL notes are deliberately deferred.

## Known limitations / next steps

- [ ] Remote (URL) note sources. `NoteSourceKind.remoteURL` exists in the model
  and decodes, but nothing creates or reads it yet.
- [ ] Detect external changes while the app is running (the file is only re-read
  at launch, so an edit in Obsidian while open gets overwritten on next save).
- [ ] Rename the file when the first heading changes (title is currently the
  file name at creation).
- [ ] Relink a note whose file was moved or deleted (`isMissing` is set but there
  is no UI yet; typing recreates the file at the old path).
- [ ] First launch reads `~/Documents` and triggers the macOS "Files and
  Folders" consent prompt. A Developer ID signature keeps that grant stable
  across rebuilds; ad-hoc builds may re-prompt. Document this for users.
- [ ] Opening `.md` files across the disk works only because the app is **not
  sandboxed**. If it is ever sandboxed, file-open needs
  `com.apple.security.files.user-selected.read-write` plus security-scoped
  bookmarks so notes outside the notes folder survive relaunch.
- [ ] Files in folders macOS protects (Desktop, Documents, Downloads, iCloud
  Drive) trigger the TCC prompt on first open — expected, but worth a README
  note.
- [ ] An iCloud/OneDrive file evicted to the cloud reads as empty
  (`String(contentsOf:)` fails); trigger a download with
  `NSFileCoordinator`/`startDownloadingUbiquitousItem` before reading.


# TODO

## Release pipeline

- [ ] Notarize the 1.3.0 build. Signing, stapling and the `spctl` gate are
      wired (`NOTARY_PROFILE=... ./build-app.sh`), but this machine has no
      `notarytool` keychain profile yet. One-time setup:
      `xcrun notarytool store-credentials "MDStickyNotes" --apple-id … --team-id TEAMID --password …`
- [ ] Publish: tag `v1.3.0`, `gh release create`, upload `build/MDStickyNotes.dmg`,
      then `spctl -a -t exec -vv` the app extracted from the downloaded DMG.
- [ ] Decide whether to add Sparkle 2 auto-updates (needs `SUFeedURL`,
      `SUPublicEDKey`, appcast per release).
- [x] `build-app.sh` accepts `CODESIGN_IDENTITY`, enables the hardened runtime,
      notarizes/staples/gates when `NOTARY_PROFILE` is set, and stops Xcode from
      injecting `get-task-allow` into distribution builds.

## Decisions

- Bundle identifier stays `com.mdstickynotes` (drop-in replacement; the fork and
  upstream are not meant to be installed side by side — they would share the
  same `UserDefaults` domain and clobber each other's notes).
- Note bodies live in external Markdown files; only metadata is indexed in
  Application Support. Remote URL notes are deliberately deferred.

## Known limitations / next steps

See [FUTURE_WORK.md](FUTURE_WORK.md) for the full list, including the sandbox
and TCC caveats, external-edit detection, iCloud placeholders, and the Notes
API proposal (`~/Projects/Notes/.work/PLAN-sticky-client.md`).

- [ ] Remote (URL) note sources, see the proposal above.
- [ ] Relink a note whose file was moved or deleted.
- [ ] Rename the backing file when the first heading changes.

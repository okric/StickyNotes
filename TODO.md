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

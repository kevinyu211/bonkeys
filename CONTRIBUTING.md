# Contributing

## Build and test

```sh
swift test                                              # unit tests
./scripts/build-app.sh                                  # builds dist/Bonkeys.app
dist/Bonkeys.app/Contents/MacOS/Bonkeys --selftest      # loads every sound without playing any
```

`./scripts/build-app.sh --install` also copies the app to `~/Applications`. You then need to allow Input Monitoring again.

## Where things are

| Folder | What's in it |
|---|---|
| `Sources/BonkeysCore` | Loading sounds, choosing one per key, and mixing. No UI, fully testable. |
| `Sources/Bonkeys` | The app: menu, settings, key listening, audio output, recording. |
| `Resources/Packs` | Fun packs, one folder each. |
| `Resources/Effects` | Sounds for special keys. |
| `Resources/Sounds` | Mechanical keyboards from kbsim. |
| `scripts` | Build, icon, and sound cutting. |

## Adding sounds

- Only CC0 (public domain) recordings, or ones you recorded yourself and release as CC0.
- Add a row to `Resources/CREDITS.md` with the link and the person who made it.
- For Freesound recordings, add the cut to `scripts/cut-sounds.sh`.
- Wanted: clean recordings of real mahjong tiles (the current keys are dominoes) and an abacus.

## Rules for code

- Never save or send which keys were pressed.
- No network connections.
- The key listener stays listen-only.

## Reporting a bug

Say which macOS version and Mac you have, which sound you used, and what you expected. If no keys make sound, first check
that Bonkeys is on under Input Monitoring, then click **Relaunch** in its menu.

# BusyMirror

BusyMirror mirrors meetings between your calendars so your availability stays consistent across accounts/devices.

## What it does (current checkpoint)
- Manual “Run” to mirror events across selected routes (Source → Targets).
- DRY-RUN mode shows what would happen.
- Prefix-based tagging of mirrored events.
- Cleanup of placeholders (with confirmation).
- Loop/duplicate guards so mirrors don’t replicate themselves.
- Time window and merge-gap settings.

## Why
Use one calendar’s confirmed meetings to block time in other calendars (e.g., corporate iPad vs. personal devices).

## Build (macOS)
Option A — Xcode
1. Open `BusyMirror.xcodeproj` in Xcode.
2. Select the BusyMirror scheme → My Mac.
3. Product → Build.  
4. Product → Archive → Distribute App → Copy App (no notarization) to export a `.app` (or ZIP it for sharing).

Option B — Makefile (reproducible)
- Build Release: `make build-release`
- Package ZIP: `make package` (creates `BusyMirror-<version>-macOS.zip` + `.sha256`)
- Built app: `build/DerivedData/Build/Products/Release/BusyMirror.app`

See `CHANGELOG.md` for notable changes.

## Roadmap
See [ROADMAP.md](ROADMAP.md)

## License
MIT — see [LICENSE](LICENSE).

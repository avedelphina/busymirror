# BusyMirror

BusyMirror mirrors meetings between your calendars so your availability stays consistent across accounts/devices.

## What it does (current)
- Route-driven mirroring (multi-source): define Source → Targets routes and run them in one go.
- Manual selection mirroring: pick a source and targets in the UI and run.
- Two privacy modes:
  - Private (hide details): mirrors placeholders with prefix + placeholder title (e.g., "🪞 Busy").
  - Mark Private: mirrors prefix + real title, but marks events Private on supported servers (best-effort).
- DRY-RUN mode: see what would be created/updated/deleted without writing.
- Overlap modes: `allow`, `skipCovered`, `fillGaps`.
- Merge adjacent events with a configurable gap.
- Time window controls (days back/forward) and Work Hours filter.
- Accepted-only filter (mirror your accepted meetings only).
- Cleanup of placeholders, including auto-delete of mirrors whose source disappeared.
- Prefix-based tagging and loop guards to prevent re-mirroring mirrors.
- Settings: autosave/restore, Import/Export JSON.

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

## CLI (optional)
- Run from Terminal with `--routes` to mirror without the UI. Example:
  - `BusyMirror.app/Contents/MacOS/BusyMirror --routes "1->2,3; 4->5" --write 1 --days-forward 7 --mode allow --exit`
- Flags exist for privacy, all-day, merge gap, days window, overlap mode, and cleanup.

## Roadmap
See [ROADMAP.md](ROADMAP.md)

## License
MIT — see [LICENSE](LICENSE).

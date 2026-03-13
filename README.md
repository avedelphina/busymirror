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
- Run the routes already saved in the app settings:
  - `BusyMirror.app/Contents/MacOS/BusyMirror --run-saved-routes --write 1 --exit`
- Flags exist for privacy, all-day, merge gap, days window, overlap mode, cleanup, and filters.
- Filters:
  - `--exclude-titles "token1, token2"`
  - `--exclude-organizers "alice@example.com, Example Org"`
  - Tokens are comma or newline separated; matching is case-insensitive.

## Logs
- BusyMirror now writes a persistent log file to `~/Library/Logs/BusyMirror/BusyMirror.log`.
- When the file grows large, the previous file is rotated to `~/Library/Logs/BusyMirror/BusyMirror.previous.log`.
- In the UI, use `Reveal Log File` to open the current log directly in Finder.

## Scheduling
- BusyMirror can create its own schedule from the app UI in `Scheduled runs`.
- Choose `Hourly`, `Daily`, or `Weekdays`, then click `Install Schedule`.
- The installed LaunchAgent runs:
  - `/Applications/BusyMirror.app/Contents/MacOS/BusyMirror --run-saved-routes --write 1 --exit`
- This is more stable than index-based `--routes`, because it uses the routes and per-route options you already configured in the UI.
- Hourly schedules use `launchd` `StartInterval`; daily and weekday schedules use `StartCalendarInterval`.
- You can remove the job from the same UI with `Remove Schedule`.
- Note: scheduled headless runs depend on Calendar permission being granted to the installed app. Because these local builds are unsigned, macOS may require re-granting permission after replacing the app bundle with a new build.

## Roadmap
See [ROADMAP.md](ROADMAP.md)

## License
MIT — see [LICENSE](LICENSE).

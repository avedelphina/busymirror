# BusyMirror

BusyMirror mirrors meetings between your calendars so your availability stays consistent across accounts/devices.

There's a macOS app and a separate, standalone iOS/iPadOS app (own routes, own calendar access — not a Mac companion, no sync between them). This README covers macOS; see [iOS/iPadOS](#iosipados) below for the other one.

On macOS, BusyMirror runs as a standard app (Dock icon, ⌘Q to quit) and also has a menu bar icon for quick sync/status without opening the main window.

## What it does (current)
- Route-driven mirroring (multi-source): define Source → Targets routes and run them in one go.
- Manual selection mirroring: pick a source and targets in the UI and run.
- Privacy: **Private** mode hides details — mirrors a placeholder with prefix + placeholder title (e.g., "🪞 Busy"). With Private off, the source title (and optionally its description) is mirrored instead. There is no option to flag mirrored events as "private" on the calendar server: EventKit has no public API for it.
- Sync Now starts in **Write** mode. To see what would happen first, use **Preview** (below); a Dry Run switch in the toolbar is still there, mainly for manual-selection mode, which has no route to preview.
- Activity Log in the app plus persistent file logging on disk.
- In-app scheduling: install or remove a `launchd` LaunchAgent from the `Scheduled runs` section.
- Menu bar controls: trigger `Sync Now`, open the main window, open Preferences, or quit.
- Overlap modes: `allow`, `skipCovered`, `fillGaps`.
- Merge adjacent events with a configurable gap.
- Time window controls (days back/forward) and Work Hours filter.
- Accepted-only filter (mirror your accepted meetings only).
- Cleanup of placeholders, including auto-delete of mirrors whose source disappeared.
- Refresh Calendars prunes stale saved calendars and routes when calendars are removed from the system.
- Prefix-based tagging and loop guards to prevent re-mirroring mirrors.
- **Preview**: a Preview button on each route (and "Preview all") lists every event Sync Now would create, update or delete — old → new title and time, grouped by target calendar and day — without writing anything.
- Per-route prefix (Global / Custom / None) and opt-in **chained mirroring** ("Mirror already-mirrored events", "Copy chained titles as-is") — see [Chained mirroring](#chained-mirroring) below.
- A "has mirrors" tag next to calendars that already contain mirrored events (from any app or device).
- Settings: autosave/restore, Import/Export JSON, saved routes for scheduled/headless runs.

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
- `--help` prints full flag documentation.
- `--list-calendars [--json]` prints available calendars (index, id, title, source/type) and exits.
- `--status [--json]` prints last-run time/result, schedule state, and saved-route count and exits.
- Flags exist for privacy, all-day, merge gap, days window, overlap mode, cleanup, and filters.
- Filters:
  - `--exclude-titles "token1, token2"`
  - `--exclude-organizers "alice@example.com, Example Org"`
  - Tokens are comma or newline separated; matching is case-insensitive.
- Exit codes: `0` success, `2` no calendar access, `3` no saved routes (with `--run-saved-routes`).

## Logs
- BusyMirror now writes a persistent log file to `~/Library/Logs/BusyMirror/BusyMirror.log`.
- When the file grows large, the previous file is rotated to `~/Library/Logs/BusyMirror/BusyMirror.previous.log`.
- `launchd` stdout/stderr for scheduled runs are also written in the same folder.
- In the UI, use `Reveal Log File` to open the current log directly in Finder.

## Scheduling
- BusyMirror can create its own schedule from the app UI in `Scheduled runs`.
- Choose `Hourly`, `Daily`, or `Weekdays`, then click `Install Schedule`.
- The installed LaunchAgent runs:
  - `/Applications/BusyMirror.app/Contents/MacOS/BusyMirror --run-saved-routes --write 1 --exit`
- This is more stable than index-based `--routes`, because it uses the routes and per-route options you already configured in the UI.
- Hourly schedules use `launchd` `StartInterval`; daily and weekday schedules use `StartCalendarInterval`.
- You can remove the job from the same UI with `Remove Schedule`, and inspect the generated plist with `Reveal LaunchAgent`.
- Note: scheduled headless runs depend on Calendar permission being granted to the installed app. Because these local builds are unsigned, macOS may require re-granting permission after replacing the app bundle with a new build.

## iOS/iPadOS

A separate, standalone app (`BusyMirroriOS` target, same Xcode project) — its own local routes and EventKit access, no Handoff/CloudKit sync with the Mac app, by design. Requires iOS/iPadOS 17.0+.

### What it does
- Route-driven mirroring with the same per-route options as Mac: Private, Copy description, Sync reminders, Mirror all-day, Merge gap, Overlap mode.
- Sync All and per-route Run, Clean Up Placeholders, a "Last synced" indicator.
- **Preview** before anything is written: a Preview button in the route add/edit form (works on the unsaved settings) and in a saved route's ⋯ menu lists every event that would be created, updated or deleted — old → new title and time, grouped by target calendar and day.
- Shortcuts/Siri support via App Intents: run one route, run all routes, or ask for status — the iOS equivalent of the Mac CLI.
- Best-effort background sync (`BGAppRefreshTask`) — iOS decides if/when it runs, no delivery guarantee. Foreground sync or a Shortcuts automation is the reliable path.
- Settings: editable mirror prefix, title/organizer skip filters.
- Calendar color chips to tell apart same-named calendars across accounts, and a "has mirrors" tag on calendars that already contain mirrored events (from either app, any device) — useful since Mac and iOS have separate calendar sets.

### Chained mirroring
A route can deliberately re-mirror an event that's already a mirror from a different route or device — e.g. an iOS route mirrors a work calendar into a shared iCloud calendar, then a Mac route mirrors that onward into other calendars. Two per-route toggles control this:
- **Mirror already-mirrored events** — off by default (the normal loop-guard skips already-mirrored source events to prevent re-mirroring). Turn on only for a deliberate chain; enabling it on a route that loops back to its own target duplicates events on every run.
- **Copy chained titles as-is** — avoids the upstream prefix stacking onto this route's own (e.g. `B: A: Meeting`). With Privacy off, the upstream title is relayed verbatim. With Privacy on (which always wins), this route's own placeholder is used but the upstream prefix is preserved, so a chained event and a genuinely native event on the same source calendar can still look different even behind placeholders.

Each route's prefix can also be set independently: inherit the global prefix, a custom per-route prefix, or no prefix at all.

### Build
- Open `BusyMirror.xcodeproj`, scheme `BusyMirroriOS`, destination = a real device (run) or **Any iOS Device (arm64)** (archive).
- Command line (no simulator needed): `xcodebuild -project BusyMirror.xcodeproj -target BusyMirroriOS -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`
- Distribution is via TestFlight (internal or external testers), not yet on the App Store.

## macOS vs iOS

Two standalone apps built from one shared mirroring engine (`MirrorEngine.swift` and friends) — same rules, same event tagging, same chained-mirroring behavior. Each app has its own routes and settings; nothing syncs between them, by design. **The goal is feature parity wherever the platform allows** (see [ROADMAP.md](ROADMAP.md) for the plan to close the gaps below).

Legend: ✅ has it · ❌ missing — a parity gap · — not applicable (platform-inherent)

| Feature | macOS | iOS/iPadOS |
|---|---|---|
| Route-driven mirroring with all per-route options | ✅ | ✅ |
| Preview — verbatim list of what would change | ✅ per route, or all routes | ✅ in the route form and ⋯ menu |
| Per-route prefix (Global / Custom / None) | ✅ | ✅ |
| Chained mirroring toggles | ✅ | ✅ |
| "has mirrors" tag on calendars | ✅ | ✅ |
| Clean Up Placeholders | ✅ | ✅ |
| Calendar color chips | ✅ | ✅ |
| Global mirror prefix, title/organizer skip filters | ✅ Preferences | ✅ Settings |
| Editable placeholder title | ✅ | ❌ fixed "Busy" |
| Sync window (days back / forward) | ✅ default 1 / 14 | ❌ fixed 1 / 14 |
| Work Hours filter | ✅ | ❌ |
| Accepted-only filter | ✅ | ❌ |
| Toggle for auto-deleting mirrors whose source disappeared | ✅ | ❌ always on |
| Defaults for newly added routes | ✅ Preferences | ❌ fixed |
| Import / Export settings JSON | ✅ same-machine backup | — not planned (see below) |
| Activity log | ✅ dedicated view + rotating log file | partial — the last run's log in the main list |
| Shortcuts / Siri (App Intents) | ❌ | ✅ |
| Manual source/target selection | ✅ | — routes only |
| Dry-run switch | ✅ optional (Sync Now starts in Write) | — use Preview |
| CLI, `launchd` schedule | ✅ | — |
| Menu bar | ✅ | — |
| Automatic sync | ✅ event-driven (see below) | best-effort only (see below) |

### Behavior differences that can surprise you
- **Sync horizon.** Both apps default to 1 day back / 14 forward. Mac lets you change it in Preferences; iOS is fixed until it gets the same setting, so a Mac with a customized window can mirror a different span than your iPhone.
- **Both apps write by default.** Sync Now on Mac and Run on iOS change calendars immediately. Use Preview first — on Mac from a route card or "Preview all", on iOS from a new route's form (it works before you even save) or a saved route's ⋯ menu. Mac also keeps an optional Dry Run switch; the command line is different and stays safe: it does nothing unless you pass `--write 1`.
- **Automatic sync.** Mac watches for calendar changes (debounced), also syncs on wake, runs as a login item with a 30-minute fallback timer, and can be scheduled or scripted. iOS has no persistent process: it syncs when opened, from a Shortcuts automation, or via a background refresh that iOS runs at its own discretion — no guarantee it runs at all. iOS shows "Last synced" so it never implies live sync.
- **Filters.** Mac can skip events outside Work Hours or that you haven't accepted; iOS mirrors every event in the window (only the title/organizer skip filters apply).
- **Placeholder title.** Mac's is editable (default "Busy"); iOS always uses "Busy". If both apps mirror into the same calendar, keep Mac's at the default or the placeholders will differ.
- **Routes and settings are per device and can't be moved between devices.** Calendar identifiers are local to each device's calendar database, so a route file from another device generally won't resolve — and Mac drops routes whose calendars it can't find at its next calendar reload. Mac's Import/Export is therefore a same-machine backup, not a way to copy routes to your iPhone, and iOS deliberately has no equivalent.
- **Run scope.** Mac's Sync Now runs all routes as one run with a shared loop-guard; iOS runs each route on its own (Sync All loops over them). Results are the same unless two routes would mirror the same event into the same target.

## Roadmap
See [ROADMAP.md](ROADMAP.md)

## License
MIT — see [LICENSE](LICENSE).

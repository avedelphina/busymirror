# BusyMirror Roadmap

## Shipped (highlights)
- Route-driven mirroring (multi-source)
- Accepted-only filter (mirror your accepted meetings)
- Persistent settings with autosave/restore; Import/Export JSON
- Overlap modes (allow, skipCovered, fillGaps) and merge-gap
- Work Hours filter and title-based skip filters
- Privacy: placeholders with prefix + customizable title
- 1.3.0: Mark Private option (global + per-route)
- 1.3.4: persistent file logging, stale-calendar pruning on refresh, clickable top-bar mode toggle
- 1.3.6: in-app scheduling via `launchd` with hourly/daily/weekday modes
- 1.3.6: generated macOS app icon set and packaged release assets
- 1.4.0: unit-test suite (45 tests), Cancel button, progress indicator, sandbox LaunchAgent fix, mirror URL fix, engine refactor into `MirrorConfig`
- CLI diagnostics: `--help`, `--list-calendars [--json]`, `--status [--json]`, real exit codes (2 = no access, 3 = no saved routes), last-run tracking (time/ok/summary)
- 1.7.0: **Event-driven background sync**, replacing the hourly `launchd StartInterval` poll. Auto-sync logic lives in `BusyMirrorAppController` (an app-lifetime object, not tied to `ContentView`'s window lifecycle — closing the main window used to tear down the `EKEventStoreChanged` observer along with it, which would have made auto-sync a no-op whenever the window was closed). Once saved routes exist: registers as a login item (`SMAppService.mainApp`), removes any old `launchd` schedule, watches `EKEventStoreChanged` (debounced ~3s) and `NSWorkspace.didWakeNotification`, plus a 30-min fallback timer as a safety net. Auto-sync always writes (`writeEnabled: true`), independent of the interactive dry-run toggle.

## Next
1. **MCP server (thin external wrapper, not embedded in the app).** So agents driving BusyMirror don't have to shell out to the CLI and regex-parse log lines. A small standalone stdio-transport script (Node/Python) maps MCP tools 1:1 onto the CLI's `--json` output: `list_calendars`, `list_routes`, `run_route`, `run_saved_routes`, `get_status`. Deliberately kept out of the Swift app itself — no MCP SDK dependency in the signed binary (AGENTS.md's zero-external-packages rule stays intact), and MCP hosts spawn server processes on demand anyway, so there's no need for the app to run one persistently.

## Then — V2 UI polish
- Finish the `ContentView.swift` split into per-section view models (Routes, Schedule, Privacy, Log) — 1.7.0 already pulled the calendar-access/auto-sync state out into `BusyMirrorAppController`; the rest (UI/settings/CLI) is still one ~1900-line file.
- Real `Settings { }` scene instead of the main window doubling as preferences.
- Menu bar icon reflects state (idle / syncing / error) instead of a static icon.
- Surface last-sync-time / last-error / next-check in the menu bar UI — the data now exists (`--status`'s `lastRunAtISO`/`lastRunOK`/`lastRunSummary`), this is just wiring it into the menu.
- Better server-side privacy mapping (per-provider heuristics).

## Later
- Signed/notarized binaries and release pipeline.
- Smarter cleanup & conflict resolution.
- iOS/iPadOS helper (Shortcuts integration).
- Profiles & MDM/Managed Config support.

## Decided against
- **Direct Google/CalDAV/Exchange API integration** (OAuth flows, token storage, per-provider clients so BusyMirror can mirror a non-local calendar without it being added to macOS). EventKit already surfaces any calendar added via System Settings → Internet Accounts — macOS does the sync, auth, and refresh. Building a parallel integration would duplicate the OS for the narrow case of an account that can't or won't be added system-wide (e.g. MDM-restricted work accounts). Not worth the OAuth/Keychain/per-provider-quirk surface for that.

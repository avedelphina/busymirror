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
- Calendar list already auto-refreshes on `EKEventStoreChanged` (does not yet trigger an auto-sync — see Next)
- CLI diagnostics: `--help`, `--list-calendars [--json]`, `--status [--json]`, real exit codes (2 = no access, 3 = no saved routes), last-run tracking (time/ok/summary)

## Next — reliability (V2 groundwork)
1. **Event-driven background sync.** The existing hourly `launchd StartInterval` only fires while the Mac happens to be awake at that instant and gets throttled/coalesced by macOS, so it's not reliable. Replace polling with reacting:
   - Keep the app running as a login item via `SMAppService.agent` instead of relying on launchd to relaunch it.
   - Extend the existing `EKEventStoreChanged` observer (today it only reloads the calendar list) to also trigger a debounced (~2-5s) auto-sync of saved routes.
   - Add an `NSWorkspace.didWakeNotification` handler to resync after sleep.
   - Keep one coarse fallback timer (e.g. every 30 min) purely as a safety net for a missed notification — not the primary mechanism.
   - `launchd`'s remaining job shrinks to "make sure the app is running," which `SMAppService` likely covers, so the plist-generation code may become unnecessary.
2. **MCP server (thin external wrapper, not embedded in the app).** So agents driving BusyMirror don't have to shell out to the CLI and regex-parse log lines. A small standalone stdio-transport script (Node/Python) maps MCP tools 1:1 onto the CLI's `--json` output: `list_calendars`, `list_routes`, `run_route`, `run_saved_routes`, `get_status`. Deliberately kept out of the Swift app itself — no MCP SDK dependency in the signed binary (AGENTS.md's zero-external-packages rule stays intact), and MCP hosts spawn server processes on demand anyway, so there's no need for the app to run one persistently.

## Then — V2 UI polish
- Split `ContentView.swift` (~1800 lines doing UI + settings + CLI + scheduling) into per-section view models (Routes, Schedule, Privacy, Log) so views are small and native-feeling.
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

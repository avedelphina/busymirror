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
- 1.8.0: **V2 UI polish.** `ContentView.swift` split from ~2000 lines into focused view files — `CalendarsSectionView`, `RoutesSectionView`, `ScheduleSectionView`, `LogSectionView` (state stays owned by `ContentView`/`@AppStorage`; these are view-layer extractions, not a full MVVM rewrite — the settings-persistence model didn't need touching and touching it is exactly how the 1.6.0/1.6.1 data-loss bug happened). A preferences window hosting the pure `@AppStorage`-backed defaults (time window, privacy/mirroring defaults, work hours, skip filters) that used to live in the main window; this surfaced a latent bug — moving fields out of `ContentView` meant they stopped re-triggering `saveSettingsToDefaults()`, so on next launch `applySnapshot` would have silently reverted a preference changed in the new window using the stale blob. Fixed by splitting launch-time restore (`restoreLaunchState`, routes/selections only, since @AppStorage fields already self-restore) from Import's full restore (`applySnapshot`, unchanged). Menu bar icon now reflects idle/syncing/error state, and the dropdown shows last-sync time/result and whether auto-sync is armed.
- 1.8.1: the preferences window (originally a `Settings{}` scene) didn't actually open — `LSUIElement` apps get no standard app menu, so Cmd+,/`SettingsLink` had no menu to hook into. Replaced with a plain `Window` opened via `openWindow(id:)`, plus a "Preferences…" menu bar item as a second entry point.
- 1.8.2: **standard app, not menu-bar-only.** Removed `LSUIElement` — Dock icon, Cmd+Tab, standard app menu (Cmd+Q) are back. The accessory-app design (no Dock icon) turned out to make the app hard to quit reliably, which blocked replacing the bundle during updates. Menu bar extra stays as a secondary quick-access point.

## Next
1. **MCP server (thin external wrapper, not embedded in the app).** So agents driving BusyMirror don't have to shell out to the CLI and regex-parse log lines. A small standalone stdio-transport script (Node/Python) maps MCP tools 1:1 onto the CLI's `--json` output: `list_calendars`, `list_routes`, `run_route`, `run_saved_routes`, `get_status`. Deliberately kept out of the Swift app itself — no MCP SDK dependency in the signed binary (AGENTS.md's zero-external-packages rule stays intact), and MCP hosts spawn server processes on demand anyway, so there's no need for the app to run one persistently.
2. **Better server-side privacy mapping (per-provider heuristics).**

## Later
- Signed/notarized binaries and release pipeline.
- Smarter cleanup & conflict resolution.
- iOS/iPadOS helper (Shortcuts integration).
- Profiles & MDM/Managed Config support.

## Decided against
- **Direct Google/CalDAV/Exchange API integration** (OAuth flows, token storage, per-provider clients so BusyMirror can mirror a non-local calendar without it being added to macOS). EventKit already surfaces any calendar added via System Settings → Internet Accounts — macOS does the sync, auth, and refresh. Building a parallel integration would duplicate the OS for the narrow case of an account that can't or won't be added system-wide (e.g. MDM-restricted work accounts). Not worth the OAuth/Keychain/per-provider-quirk surface for that.

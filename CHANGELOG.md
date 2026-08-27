# Changelog

All notable changes to BusyMirror will be documented in this file.

## [1.9.0] - 2026-08-27

### Added
- **Sidebar navigation redesign.** Main window is now a `NavigationSplitView`: a sidebar (Routes / Schedule / Activity Log, with a route-count badge) replaces the old 2×2 grid of panel cards. Primary actions (Dry Run/Write, sync status, Sync Now) moved to the window toolbar; Export/Import/Reveal Log/Cleanup Placeholders/Refresh Calendars/Recheck Permission moved into a toolbar overflow menu.
- **Routes** are now a real collapsed-by-default list — click a row to expand its editor (Private, Copy description, Sync reminders, Mirror all-day, merge gap, overlap, Remove) instead of every route always showing every field. The manual source/target picker lives in a collapsible "Manual Selection" section above the list.
- **Schedule** view leads with live auto-sync status (armed/watching, last sync) instead of a bare `launchd` form; the manual fixed-time schedule is still there, demoted to an explicitly optional section underneath — matches what it actually became once 1.7.0 shipped event-driven sync.
- **Activity Log** is now readable rows (status icon + text) instead of a monospaced text dump, with a search filter and a Clear button for the in-app view (the persistent file log on disk is untouched).
- Menu bar dropdown got icons on every item and real ⌘,/⌘Q keyboard shortcuts on Preferences/Quit.
- Design explored first as a mockup (light+dark) before any SwiftUI changes; direction confirmed before implementing.

### Fixed
- **Routes silently dropped on most launches, masked by a legacy fallback.** `reloadCalendars()` pruned routes referencing calendars not in the current EventKit fetch — but the fetch immediately following a permission grant (a freshly-created `EKEventStore`) can under-report calendars for a moment, especially remote accounts (Exchange/CalDAV), before they finish loading. Every affected launch wrongly deleted real routes, and only kept working because of a legacy `routes.v1` backup key kept rescuing them — a backup that itself was frozen at whatever it held the first time it was ever written, since nothing updated it afterward. Any real route edit made in a session that hit this bug would have been silently lost on the next launch. Fixed by skipping the prune specifically on the post-permission-grant reload (`reloadCalendars(pruneRoutes: false)`) — the EKEventStoreChanged-triggered reload and an explicit "Refresh Calendars" click, both against an already-warm store, still prune as before — and by keeping the `routes.v1` backup itself current on every save instead of frozen. Confirmed via `--status`/reading the UserDefaults plist directly on a real install: routes stopped disappearing across repeated launches. ([ContentView.swift](BusyMirror/ContentView.swift))

## [1.8.3] - 2026-08-27

### Fixed
- **Preferences missing from the standard app menu.** 1.8.1's fix for Preferences (a plain `Window` opened via `openWindow`) worked around `LSUIElement` having no app menu, but 1.8.2 removed `LSUIElement` and the workaround was never swapped back — so there was still no "Preferences…" in the app's own menu or Cmd+, response, only a button buried in the main window and a menu-bar-dropdown item. Restored a real `Settings { }` scene now that the app menu exists to host it; both the menu bar dropdown and the main window's button now call the standard `openSettings()` action (via `SettingsLink` in the main window) instead of a custom `openWindow(id:)`. ([BusyMirrorApp.swift](BusyMirror/BusyMirrorApp.swift), [MenuBarSupport.swift](BusyMirror/MenuBarSupport.swift), [ContentView.swift](BusyMirror/ContentView.swift))

## [1.8.2] - 2026-08-27

### Changed
- **Standard app instead of menu-bar-only.** Removed `LSUIElement` from `Info.plist`: BusyMirror now shows a Dock icon, appears in Cmd+Tab, and gets the standard app menu (Cmd+Q to quit, among others). The menu bar extra stays as a secondary quick-access point. This also fixes the practical problem it was causing: with no Dock icon and no accessible app menu, there was no reliable way to quit the app to let an update replace the bundle — you had to know the menu bar dropdown's "Quit BusyMirror" existed and use exactly that. Verified via `lsappinfo` (`type="Foreground"`, previously `UIElement`) since this app type change isn't something a screenshot would catch either.

## [1.8.1] - 2026-08-26

### Fixed
- **Preferences window unreachable**: 1.8.0's Settings scene (⌘,) and its `SettingsLink` button didn't work because BusyMirror is an `LSUIElement` (accessory) app — those don't get the standard app menu, so there's no menu for the automatic "Settings…" command or Cmd+, to live in. Replaced the `Settings { }` scene with a plain `Window(id: "preferences-window")`, opened via `openWindow(id:)` — the same mechanism that already reliably opens the main window from the menu bar. Also added a "Preferences…" item to the menu bar dropdown itself, so there are two direct routes in instead of one that depended on OS menu plumbing this app type doesn't get. ([BusyMirrorApp.swift](BusyMirror/BusyMirrorApp.swift), [MenuBarSupport.swift](BusyMirror/MenuBarSupport.swift), [ContentView.swift](BusyMirror/ContentView.swift))

## [1.8.0] - 2026-08-26

### Added
- **Real Settings (⌘,) window**: `PreferencesView` now hosts the pure-defaults controls (time window, privacy/mirroring defaults, title prefix/placeholder, work hours, skip filters) that used to live in the main window's "General Settings" panel. They're `@AppStorage`-backed so both windows always see the same live values. Main window keeps everything with session/live state: routes, calendar picker, dry-run toggle, Export/Import, manual scheduling, cleanup.
- **Menu bar icon reflects state**: idle (`calendar.badge.clock`), syncing (`arrow.triangle.2.circlepath.circle.fill`), or last run failed (`exclamationmark.triangle.fill`).
- **Menu bar dropdown diagnostics**: last-sync time and result, and whether auto-sync is currently armed — sourced from the same `lastRunAtISO`/`lastRunOK`/`lastRunSummary` keys `--status` reads, so CLI/interactive/auto-sync runs all feed the same indicator.
- **`ContentView.swift` split** from ~2000 lines into `CalendarsSectionView`, `RoutesSectionView`, `ScheduleSectionView`, `LogSectionView` (plus a small shared `CalendarDisplay.swift`). View-layer extraction — state ownership and settings persistence were deliberately left untouched, since that's exactly the area the 1.6.0/1.6.1 release had to fix a real data-loss bug in.

### Fixed
- **Latent revert-on-relaunch bug**, caught while building the Settings window: moving the `@AppStorage`-backed preference controls out of `ContentView` meant changing them no longer re-triggered `saveSettingsToDefaults()`, so the `settings.v2` snapshot blob could go stale relative to the individual UserDefaults keys. Since `loadSettingsFromDefaults()` used the same full `applySnapshot` as Import, the next launch would silently revert a preference you'd just changed in Preferences back to whatever the stale blob had. Fixed by splitting launch-time restore into a narrow `restoreLaunchState` (routes + manual selection only — the only state that isn't already self-restoring via `@AppStorage`) separate from `applySnapshot` (unchanged, still used by Import where overwriting everything is the point). ([ContentView.swift](BusyMirror/ContentView.swift))

## [1.7.0] - 2026-08-26

### Added
- **Event-driven background sync**, replacing the hourly `launchd StartInterval` poll (which only fired if the Mac happened to be awake at that instant, and got throttled/coalesced by macOS). Once saved routes exist, the app registers as a login item (`SMAppService.mainApp`), removes any previously-installed `launchd` schedule, and reacts to `EKEventStoreChanged` (debounced ~3s), `NSWorkspace.didWakeNotification` (resync after sleep), and a 30-minute fallback timer as a safety net for a missed notification. Auto-sync always writes (`writeEnabled: true`) regardless of the interactive dry-run toggle, matching what the old scheduled `--write 1` runs did.
- This logic lives in `BusyMirrorAppController`, not `ContentView` — the controller is owned by the `App` struct for the whole process lifetime, whereas `ContentView`'s own `EKEventStoreChanged` observer is torn down in `.onDisappear` when the main window closes (confirmed: `MenuBarSupport.swift`'s "Sync Now" already reopens the window before syncing, which only makes sense if the window's state is discarded on close). Auto-sync needs to work with the window closed, so it can't live there. ([MenuBarSupport.swift](BusyMirror/MenuBarSupport.swift))

## [1.6.1] - 2026-08-26

### Added
- **Sync reminders**: new "Sync reminders when mirroring" option (global and per-route) copies source event alarms/relative offsets into mirrored placeholders. This lets calendars that are synced to a phone ring for mirrored events. When merging is enabled, only the first event's alarms are preserved for a merged block. ([ContentView.swift](BusyMirror/ContentView.swift), [MirrorEngine.swift](BusyMirror/MirrorEngine.swift), [BlockMath.swift](BusyMirror/BlockMath.swift))
- CLI flag `--sync-reminders` to enable reminder syncing from scripted/headless runs.
- CLI polish: `--help`/`-h`, `--list-calendars`, and `--status` (all support `--json` for machine-readable output). Scheduled/headless runs now record last-run time, success/failure, and a summary so `--status` can report real diagnostics instead of just log-file grepping. Failure paths (`no calendar access`, `no saved routes`) now exit with distinct nonzero codes instead of always exiting 0. ([ContentView.swift](BusyMirror/ContentView.swift))

### Fixed
- **Settings silently wiped on upgrade**: `SettingsPayload` used fully auto-synthesized `Codable`, so decoding a settings blob written by an older build (missing a field added since, e.g. `syncReminders`) threw `keyNotFound` and failed the *entire* decode — not just that one field. The app then ran with in-code defaults (empty routes, filters, etc.), and the next autosave persisted that empty state back over the real data. `SettingsPayload` now has a custom `init(from:)` that reads every field added after the first release with `decodeIfPresent` + its existing default, matching the pattern `Route` already used. `loadSettingsFromDefaults()` also now recovers routes from the legacy `routes.v1` backup key if `settings.v2` decodes successfully but with an empty `routes` array — repairing installs that already hit this bug before upgrading. ([ContentView.swift](BusyMirror/ContentView.swift), [SettingsPayloadTests.swift](BusyMirrorTests/SettingsPayloadTests.swift))

## [1.5.1] - 2026-05-27

### Fixed
- **Mirror index dirtied on every sync**: `MirrorRecord` used synthesized `Equatable` which included `updatedAt: Date = Date()`. Because `updatedAt` is set to the current time whenever a record is constructed, the comparison used to detect changes always returned "not equal", causing `UserDefaults` to be written on every sync run even when nothing changed. A custom `==` / `hash(into:)` now excludes `updatedAt`. ([MirrorEngine.swift](BusyMirror/MirrorEngine.swift))
- **Mirror URL corruption with special characters in calendar IDs**: `buildMirrorURL` placed raw calendar and source IDs into the URL path without percent-encoding them. If any ID contained the `;` separator character the resulting URL would be mis-parsed on the next sync. `mirrorURLComponentEncode` (which already existed and was tested) is now called on all ID fields before they are joined. The path is set via `percentEncodedPath` to prevent `URLComponents` from double-encoding the already-encoded values. ([MirrorUtils.swift](BusyMirror/MirrorUtils.swift))
- **Dead constant**: removed unused `SKIP_ALL_DAY_DEFAULT = true` from `ContentView.swift`.
- **Deprecated `FileHandle` API**: replaced `FileHandle(forWritingAtPath:)` + `handle.closeFile()` with the modern throwing `FileHandle(forWritingTo:)`, `handle.seekToEnd()`, and `handle.write(contentsOf:)` in `AppLogStore`. ([AppLogStore.swift](BusyMirror/AppLogStore.swift))
- **Cleanup jumps calendar picker**: `runCleanupForRoute` was mutating `sourceIndex`, `sourceID`, and `targetIDs` during route cleanup, visibly shifting the picker in the UI. Cleanup does not need to update the UI selection; those mutations are removed.
- **`--exit` flag redundancy**: `NSApp.terminate` was called whenever `isCLIRun` was true, making `--exit` a no-op. The app now exits only when `--exit` is explicitly passed, so `--routes` / `--run-saved-routes` can be used without forcing termination.

### Added
- **Live calendar refresh**: the calendar list now updates automatically when the system calendar database changes (`EKEventStoreChanged` notification), removing the need to press "Refresh Calendars" after adding or removing a calendar. The observer is unregistered on view disappear and re-registered when the `EKEventStore` is recreated. ([ContentView.swift](BusyMirror/ContentView.swift))

### Changed
- **`AppLogStore` extracted**: moved from an inline private enum in `ContentView.swift` to its own file `AppLogStore.swift` for easier navigation. ([AppLogStore.swift](BusyMirror/AppLogStore.swift))
- **`Block.span` factory**: added `Block.span(start:end:)` to replace the repetitive `Block(start:end:srcStableID:nil:label:nil:notes:nil:occurrence:nil)` construction pattern throughout `BlockMath.swift` and `MirrorEngine.swift`. ([BlockMath.swift](BusyMirror/BlockMath.swift))
- **Removed redundant `MainActor.run` wrappers**: `MirrorEngine` is `@MainActor`; wrapping `store.save` / `store.remove` in `try await MainActor.run { }` was unnecessary and added overhead. ([MirrorEngine.swift](BusyMirror/MirrorEngine.swift))
- **`SettingsPayload` indentation**: the nested struct was de-dented to column 0 inside `ContentView`, making it look like a top-level type. Indentation is now consistent with the surrounding members.

### Build
- Bump version to **1.5.1** (build **20**).

## [1.5.0] - 2026-05-27

### Removed
- **Mark Private feature**: removed the non-functional server-side "Private" flagging for mirrored events. The Objective-C runtime hack (`setPrivate:`, KVC on `sensitivity`/`classification`) never worked reliably and would have blocked App Store review. This simplifies the UI and removes a private-API liability.

### Changed
- **Extracted mirror engine**: the ~500-line `runMirror` and `runCleanup` logic has been moved from `ContentView.swift` into a new `MirrorEngine.swift` class. `ContentView` now delegates to the engine via `makeEngine()`.
- `MirrorRecord`, mirror index persistence, and `SAME_TIME_TOL_MIN` now live in the engine module.
- `calLabel` moved to `MirrorUtils.swift` so it can be shared between UI and engine.

### Build
- Bump version to **1.5.0** (build **19**).

## [1.4.0] - 2026-05-27

### Fixed
- **Sandbox LaunchAgent**: added `temporary-exception` entitlement so scheduled runs work in the sandboxed app.
- **Mirror URL generation**: `buildMirrorURL` was silently broken — `URL(string:)` rejects raw `|` characters on current macOS, so mirror metadata URLs were always `nil`. Rebuilt with `URLComponents` using `;` separator and backward-compatible parser.
- **Crash on Cleanup**: `runCleanup()` no longer crashes if the selected source calendar was removed.
- **State corruption in multi-route runs**: `runConfiguredRoutes` no longer mutates global `@State` settings and restores them at the end of each loop; instead it passes a `MirrorConfig` struct into the engine.
- **KVC safety**: removed misleading `do-catch` around `setValue:forKey:` in `setEventPrivateIfSupported()` (Objective-C exceptions are uncatchable in Swift).
- **Log memory leak**: in-memory log now caps at 2,000 lines.
- **CLI race**: `tryRunCLIIfPresent()` now preloads calendars when access is already granted, eliminating the 10-second timeout race.
- **launchCtl output**: stdout and stderr now use separate pipes instead of interleaving into one.

### Added
- **Cancel button**: long-running mirrors now show a Cancel button; loops check `Task.isCancelled` for responsive cancellation.
- **Progress indicator**: multi-route runs display `"Route X of Y"` in the status area.
- **Unit tests**: 45 tests across `BlockMathTests`, `MirrorUtilsTests`, and `EventFiltersTests`.
- **Extracted modules**: `BlockMath.swift`, `MirrorUtils.swift`, `EventFilters.swift`, and `MirrorConfig.swift` separate pure logic from the UI monolith.
- **Target event cache**: target calendars shared across routes are fetched only once per run session.

### Changed
- `mergeGapMin` is now a computed property instead of redundant `@State`.
- Log editor is now read-only (still selectable/copyable).
- `SettingsPayload.excludedOrganizerFilters` is now non-optional for consistency.

### Build
- Bump minimum macOS version to `15.5` in `Info.plist`.
- Bump version to **1.4.0** (build **18**).

## [1.3.9] - 2026-04-09
- New: add a macOS menu bar extra with `Sync Now`, `Open BusyMirror`, and `Quit BusyMirror`.
- UX: menu bar sync requests reuse the existing mirror flow and can open the main window automatically when needed.
- UX: BusyMirror now runs as a menu bar-only app and no longer appears in the Dock.
- Build: bump version to 1.3.9 (build 17).

## [1.3.8] - 2026-04-08
- Fix: release ZIPs now package `BusyMirror.app` at the archive root instead of embedding the full build path.
- Fix: release builds now apply an ad-hoc bundle signature before packaging so downloaded artifacts pass `codesign --verify --deep --strict`.
- Build: suppress resource fork sidecars in release ZIPs via `ditto --norsrc --keepParent`.
- Build: bump version to 1.3.8 (build 16).

## [1.3.7] - 2026-03-24
- Fix: mirror reconciliation now survives target providers that strip BusyMirror's custom event URL metadata.
- Fix: moved and deleted source events are tracked via stable EventKit identifiers and a persisted local mirror index, so target placeholders update reliably.
- Fix: mirror updates now detect title and notes changes, not just start/end time changes.
- Build: bump version to 1.3.7 (build 15).

## [1.3.6] - 2026-03-13
- Scheduling: add in-app `Scheduled runs` controls to install or remove a user `launchd` LaunchAgent from BusyMirror itself.
- Scheduling: support `Hourly`, `Daily`, and `Weekdays` schedules; hourly mode runs saved routes via `StartInterval`.
- UX: generate and ship a proper macOS app icon set for BusyMirror.
- Build: bump version to 1.3.6 (build 14).

## [1.3.4] - 2026-03-13
- Fix: route-scoped cleanup no longer deletes placeholders created by other source routes during the same multi-route run.
- Fix: stale calendars are pruned from saved selections and routes during refresh, and refresh now recreates `EKEventStore` for a hard reload.
- UX: the top bar `DRY RUN` / `WRITE` status pill is clickable, the left column keeps its own height on desktop, and the app can reveal its log file from the UI.
- Logging: mirror activity is persisted to `~/Library/Logs/BusyMirror/BusyMirror.log` with simple rotation to `BusyMirror.previous.log`.
- CLI: add `--run-saved-routes` so scheduled `launchd` runs can use the saved UI routes instead of fragile index-based route definitions.

## [1.3.1] - 2025-10-13
- Fix: auto-delete of mirrored placeholders when the source is removed now works even if no source instances remain in the window. Also cleans legacy mirrors without URLs by matching exact times.

## [1.3.2] - 2025-10-13
- New: Organizer filters — skip events by organizer (name/email/URL). UI under Options and persisted in settings.
- CLI: add `--exclude-organizers` (and `--exclude-titles`) flags to control filters when running headless.

## [1.2.4] - 2025-10-10
- Fix: enable “Mirror Now” when Routes are defined even if no Source/Targets are checked in the main window. Button now enables if either routes exist or a manual selection is present.

## [1.3.0] - 2025-10-10
- New: Mark Private option to mirror with prefix + real title and set event privacy on supported servers; available globally and per-route; persisted.
- Misc: calendar access fixes, concurrency annotations, accepted‑only filter, settings autosave/restore, Mirror Now enablement.

## [1.2.3] - 2025-10-10
- Fix: reliably save and restore settings between runs via autosave of key options and restoration of source/target selections by persistent IDs.
- UX: persist Source and Target selections; rebuild indices on launch so UI matches saved IDs.
- Build: bump version to 1.2.3 (build 5).

## [1.2.1] - 2025-10-10
- Fix: reinitialize EKEventStore after permission grant to avoid “Loaded 0 calendars” right after approval.
- Fix: attendee status filter uses current user’s attendee `participantStatus == .accepted` instead of unavailable APIs.
- Concurrency: mark `requestAccess()` and `reloadCalendars()` as `@MainActor` to satisfy strict concurrency checks.
- Dev: add Makefile with `build-debug`, `build-release`, and `package` targets; produce versioned ZIP + SHA-256.

## [1.2.0] - 2024-09-29
- Feature: multi-route mirroring, overlap modes, merge gaps, work hours filter, CLI support, export/import settings.

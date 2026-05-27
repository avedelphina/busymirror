# Changelog

All notable changes to BusyMirror will be documented in this file.

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

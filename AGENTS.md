# BusyMirror — Agent Reference

> This file is written for AI coding agents. It assumes you know nothing about the project.

## Project Overview

**BusyMirror** is a macOS utility (standard app + menu bar extra) that mirrors calendar events from a source calendar into one or more target calendars, creating busy-placeholder events so availability stays consistent across accounts and devices.

It is written in **Swift 5** and **SwiftUI**, using **EventKit** to read and write calendar data. The macOS app runs as a standard app (Dock icon, ⌘Q) and also has a `MenuBarExtra` for quick sync/status. There's also a **separate, standalone iOS/iPadOS app** (`BusyMirroriOS` target, same Xcode project) — not a Mac companion, no Handoff, no cross-device state sync, own local routes and EventKit access. The two platforms version independently (see "Versioning" below). See "iOS/iPadOS target" below and `ROADMAP.md` for the full feature history.

Key capabilities (macOS):
- Manual or route-driven multi-source mirroring
- Privacy mode: hide details (placeholder title)
- DRY-RUN mode to preview changes without writing
- Scheduled headless runs via a self-installed `launchd` LaunchAgent
- Settings autosave/restore, plus Import/Export JSON
- CLI support for headless/scripted runs
- Preview (per route and all routes) listing every create/update/delete verbatim, per-route prefix mode (Global/Custom/None), chained-mirroring toggles, "has mirrors" tag — all at parity with iOS

Key capabilities (iOS/iPadOS):
- Route-driven mirroring, same per-route option set as Mac (Private, Copy description, Sync reminders, Mirror all-day, Merge gap, Overlap mode)
- Shortcuts/Siri via App Intents (run one route, run all, status) — the iOS equivalent of the Mac CLI
- Best-effort background sync (`BGAppRefreshTask`, no delivery guarantee — foreground/Shortcuts-triggered is the reliable path)
- **Chained mirroring**: per-route toggles to deliberately re-mirror an already-mirrored event across devices (e.g. phone mirrors Work → shared iCloud calendar, Mac mirrors that onward) — see "Chained mirroring" below
- Per-route prefix mode (Global / Custom / None) and cross-device "already mirrored" detection
- **Preview**: a Preview button in the route add/edit form (works on the unsaved form state) and in a saved route's ⋯ menu lists every create/update/delete verbatim — old → new title and time, grouped by target calendar and day — instead of dry-run log lines nobody scrolls on a phone. See "Preview" below.

## Technology Stack

| Layer | Technology |
|-------|------------|
| Language | Swift 5.0 |
| UI Framework | SwiftUI (+ AppKit on macOS for the menu bar/panels) |
| Calendar API | EventKit (`EKEventStore`, `EKEvent`, `EKCalendar`) |
| Persistence | `UserDefaults` (JSON-encoded settings), `@AppStorage` (macOS) |
| Scheduling | `launchd` / `launchctl` (macOS LaunchAgent); `BGTaskScheduler` (iOS, best-effort) |
| Automation | CLI flags (macOS); App Intents / Shortcuts (iOS) |
| Build System | Xcode project (`BusyMirror.xcodeproj`) + Makefile (macOS release pipeline) |
| Target OS | macOS 15.5+, iOS/iPadOS 17.0+ |
| Signing | macOS: Developer ID + notarized (`make package`). iOS: automatic signing, TestFlight for distribution |

No external Swift Package Manager dependencies are used. The project is self-contained.

## Project Structure

```
BusyMirror/                      # macOS app target
├── BusyMirrorApp.swift          # App entry point; defines Window + MenuBarExtra
├── ContentView.swift            # Main UI, settings, CLI, scheduling
├── RoutesSectionView.swift      # Routes list/editor (split out of ContentView in 1.8.0)
├── CalendarsSectionView.swift   # Calendar picker section
├── ScheduleSectionView.swift    # launchd scheduling UI
├── LogSectionView.swift         # Activity log view
├── PreferencesView.swift        # Settings window (@AppStorage-backed defaults)
├── MenuBarSupport.swift         # `BusyMirrorAppController` (state coordinator, auto-sync) + menu bar view
├── MirrorEngine.swift           # EventKit mirror engine (read, deduplicate, merge, create/update/delete) — shared with iOS
├── MirrorConfig.swift           # Route + MirrorConfig structs — shared with iOS
├── MirrorUtils.swift            # URL builders, mirror detection, calendar labels, title marker — shared with iOS
├── BlockMath.swift              # Block merging, gap calculation, overlap logic (Block.span factory) — shared with iOS
├── EventFilters.swift           # Work-hours, title, and organizer filters — shared with iOS
├── CalendarDisplay.swift        # calColor/calChip/calLabel view helpers — shared with iOS
├── PlannedChange.swift          # PlannedChange model + grouping/summary/title-reason helpers (pure, unit-tested) — shared with iOS
├── PlannedChangesSheet.swift    # Preview sheet UI (grouped, verbatim change list) — shared with iOS
├── AppLogStore.swift            # File-backed log store with rotation — shared with iOS
├── Info.plist                   # calendar/reminders usage descriptions
├── BusyMirror.entitlements      # App sandbox + calendar access entitlement
└── Assets.xcassets/             # AppIcon set and accent color

BusyMirroriOS/                   # iOS/iPadOS app target — see "iOS/iPadOS target" below

BusyMirror.xcodeproj/            # Xcode project (PBXFileSystemSynchronizedRootGroup — new .swift files are auto-included per target's folder)
BusyMirrorTests/                 # Unit tests: BlockMathTests, EventFiltersTests, MirrorUtilsTests, SettingsPayloadTests, PlannedChangeTests, RouteCodingTests (82 tests)
BusyMirrorUITests/                # UI tests (empty)
```

**Architecture note:** `ContentView.swift` handles the SwiftUI view hierarchy, settings serialization, CLI argument parsing, `launchd` scheduling, and logging; `RoutesSectionView`/`CalendarsSectionView`/`ScheduleSectionView`/`LogSectionView` are view-layer extractions (state stays owned by `ContentView`/`@AppStorage`). The EventKit mirror engine lives in `MirrorEngine.swift` and is invoked from `ContentView` via `makeEngine()`. Pure helper logic (block math, filters, URL utilities, mirror detection) has been extracted into standalone files for testability — these same files are shared with the iOS target unchanged.

When making changes, keep the existing data flow (`@EnvironmentObject`, `@AppStorage`, `@State`) intact in `ContentView.swift`.

## iOS/iPadOS target

`BusyMirroriOS` is a second app target in the same `BusyMirror.xcodeproj` (iOS 17.0+, iPhone + iPad). It is **not** a Mac companion — standalone app, own local routes, own EventKit access, no iCloud/CloudKit/Handoff sync with the Mac app (deliberate decision, see `ROADMAP.md`).

```
BusyMirroriOS/
├── BusyMirroriOSApp.swift   # App entry point (WindowGroup, no MenuBarExtra) + BGAppRefreshTask registration
├── ContentView.swift        # Routes list, add/edit/delete, Sync All, Clean Up Placeholders, Settings sheet
├── RouteStore.swift         # @MainActor singleton: route persistence, calendar access, run/preview/cleanup — shared by ContentView and the App Intents so both call the same logic
├── RouteIntents.swift       # App Intents (RunRouteIntent, RunAllRoutesIntent, GetStatusIntent) + AppShortcutsProvider
├── Info.plist                # NSCalendarsFullAccessUsageDescription, BGTaskSchedulerPermittedIdentifiers, UIBackgroundModes
└── Assets.xcassets/          # AppIcon (full multi-size iOS iconset, flattened to opaque — see "Icons" note below)
```

The iOS target shares these files from `BusyMirror/` via a `PBXFileSystemSynchronizedRootGroup` target-membership exception (see `project.pbxproj` — no file duplication, no separate copies to keep in sync): `MirrorEngine.swift`, `MirrorConfig.swift`, `BlockMath.swift`, `EventFilters.swift`, `MirrorUtils.swift`, `AppLogStore.swift`, `CalendarDisplay.swift`, `PlannedChange.swift`, `PlannedChangesSheet.swift`. `Route`, `OverlapMode` and `PrefixMode` live in `MirrorConfig.swift` (not `ContentView.swift`) specifically so both targets can use them. These files must stay AppKit-free (pure Foundation/EventKit, `#if os(macOS)` for any platform-specific branch — see `CalendarDisplay.swift`'s `calColor` for the pattern) since they compile into both targets.

Everything else in `BusyMirror/` (AppKit, `launchd`, CLI, menu bar, preferences window: `ContentView.swift`, `BusyMirrorApp.swift`, `MenuBarSupport.swift`, `PreferencesView.swift`, `RoutesSectionView.swift`, `CalendarsSectionView.swift`, `ScheduleSectionView.swift`, `LogSectionView.swift`) is excluded from the iOS target and stays Mac-only.

Build/test the iOS target from the command line (no simulator runtime required — this builds against the device SDK with signing disabled):
```
xcodebuild -project BusyMirror.xcodeproj -target BusyMirroriOS -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

**Icons gotcha:** the iOS target's `ASSETCATALOG_COMPILER_APPICON_NAME` must be set and `Assets.xcassets` must contain a valid opaque 1024×1024 App Store icon before an archive will validate. iOS rejects an alpha channel on that icon (unlike macOS, which expects one). Also, a brand-new iOS target created via `new_target` in Xcode's project API doesn't set `GENERATE_INFOPLIST_FILE = YES` the way the template-generated Mac target does — without it, `CFBundleIdentifier`/`CFBundleExecutable`/version keys never get merged into the built Info.plist, which silently breaks the App Intents metadata build step (`AppIntentsSSUTraining`) with "Unable to parse Info.plist".

## Preview (dry-run as structured data)

`MirrorEngine` has an optional `onPlannedChange` callback, invoked once per change a **dry run** (`writeEnabled == false`) would make — the structured twin of the `~ WOULD UPDATE` / `+ WOULD CREATE` / `~ WOULD DELETE` log lines, at all five of those sites (create, update, two delete paths in `runMirror`, plus `runCleanup`). It is never called for real writes. `PlannedChange` (`PlannedChange.swift`) carries kind, target calendar, old/new title and time, and — for updates — the *reasons* (`time`, `title`, `marker`, `notes`, `allDay`, `link`, `reminders`); `needsUpdate` became `updateReasons` (empty = up to date) to produce them. A title that differs only by the invisible chain marker gets its own `marker` reason, because otherwise the first resync after the marker rollout would show many updates whose old and new titles look identical.

For a preview to match what applying would do, the dry-run branches keep the same bookkeeping a real run does: they extend `occupied` and record the time key (`placeholderSet`) after each would-be create/update, so `skipCovered`/`fillGaps` and identical-time source events behave the same as in a real run, and the create counter is incremented in dry-run like the update counter already was. Dry run still persists the mirror index (an invisible normalization of already-existing mirrors, pre-existing behavior) but writes no calendar data.

macOS: `ContentView.makeRouteConfig(for:writeEnabled:)` is the single place a route's `MirrorConfig` is built — real runs (`runConfiguredRoutes`) and `previewChanges(for:)` both use it, so a preview can't drift from Sync Now. Unlike iOS, Mac previews run with `isMultiRouteRun: true` and one shared loop-guard across routes, because that's how Mac always runs (the flag changes auto-delete behavior for legacy events), and `previewChanges` deliberately doesn't touch the UI's source/target selection or progress state (which `runConfiguredRoutes` does) or the Activity Log. Entry points: a Preview button in each expanded route card, and "Preview all" in the routes header.

iOS: `RouteStore.preview(route:calendars:)` runs the engine with `writeEnabled: false` and collects the changes; it never updates "Last synced". `RouteFormView.makeRoute()` builds the route from current (unsaved) form state and is shared by Save and Preview, so a preview always matches what saving would run. Preview shows a *snapshot of right now* — it is not a plan that Apply executes; saved routes' Run / Sync All still write immediately (preview them first via the ⋯ menu).

## Chained mirroring

A route can deliberately re-mirror an event that's already a mirror from a different route/device — e.g., an iOS route mirrors Work → a shared iCloud calendar, then a Mac route mirrors that shared calendar onward to other calendars. Two per-route `Route` fields (`MirrorConfig.swift`) control this, both default `false`/off (normal loop-guard behavior unchanged):

- **`mirrorMirroredEvents`**: bypasses the loop-guard (`MirrorEngine.swift`, the `isMirrorEvent` check before a source event is skipped) for that route's source read. Detection is via the `mirror://...` URL tag every mirror event carries (`MirrorUtils.swift`'s `buildMirrorURL`/`isMirrorEvent`) — independent of title prefix, app, or device, so it works across the Mac/iOS boundary even though the two don't share routes or settings.
- **`passThroughMirroredTitles`**: only meaningful with the above on. Without it, re-prefixing an already-mirrored title stacks (e.g. `B: A: Meeting`). With Privacy off, the upstream title is relayed completely verbatim. With Privacy on (which always wins — a Private route can never leak an upstream title just because pass-through is on), this route's own placeholder is used but the upstream route's *prefix* is preserved via `mirrorTitleMarker` (`MirrorUtils.swift`, an invisible U+2063 marker embedded right after a route's own prefix on every newly-built title) and `extractMirrorPrefix(from:)`. This lets a chained event (e.g. `WORK1: Busy`) and a genuinely native event on the same source calendar (e.g. `WORK: Busy`, this route's own prefix) stay distinguishable even though both are hidden behind placeholders — detection (`Block.isMirrorSource`) happens per event, not per calendar, so a source calendar can mix both kinds.

Route's third prefix-related field, `titlePrefix: String?`, has three states: `nil` = inherit the app's global prefix, `""` = no prefix at all, non-empty = custom override (`PrefixMode` in `MirrorConfig.swift` models this as a Global/Custom/None choice for both UIs). Both apps expose all three fields: iOS in `RouteFormView`, Mac in each route card in `RoutesSectionView` (`RoutePrefixEditor` + the two toggles). Mac honors `Route.titlePrefix` in every path that builds a config: `ContentView.makeRouteConfig`, the background auto-sync in `MenuBarSupport.swift`, and `runCleanupForRoute`.

The "has mirrors" tag (`mirroredCalendarIDs(among:store:)` in `MirrorUtils.swift`, `mirrorBadge` in `CalendarDisplay.swift` — a neutral text pill, not a warning icon, since a triangle read as "something is wrong with this calendar") is shown next to *sources* and in pickers, not next to a route's own targets — those hold its mirrors by design, so a badge there is just noise. The scan is a synchronous EventKit fetch (±60 days), so Mac runs it on first load, explicit Refresh, and when the calendar count changes — not on every `EKEventStoreChanged`, which `reloadCalendars` handles constantly.

## Feature parity (macOS ↔ iOS)

**Aim for parity wherever the platform allows** (the user's standing preference): build a feature on both platforms in the same change, or say explicitly why one is missing it. Parity is about *features*, not data — the apps stay standalone (no Handoff/CloudKit sync), and routes can't be moved between devices anyway (calendar identifiers are local to each device's calendar database).

**The canonical status table and the user-facing behavior differences live in `README.md` ("macOS vs iOS") — update it whenever a feature lands on one platform or a gap closes.** `ROADMAP.md` ("Next" → feature parity) holds the plan for the open gaps. Don't copy the table here; it will drift.

Engine-level differences worth knowing when touching shared code (all deliberate today, but they're where "same code, different result" comes from):

- **Config builders are per-platform.** Mac: `ContentView.makeRouteConfig(for:writeEnabled:)` (manual runs and Preview) and a separate builder in `MenuBarSupport.swift` (background auto-sync, reads a settings snapshot). iOS: `RouteStore.run`. A new `MirrorConfig` field has to be wired into all three, and `route.titlePrefix ?? global` applied in each.
- **`isMultiRouteRun`:** Mac always runs routes together (`true`, shared `sessionGuard`); iOS runs each route alone (`false`). The flag changes legacy-event auto-delete behavior, so a Mac preview must pass `true`.
- **Defaults:** both apps default to a 1-day-back / 14-day-forward window, from the shared `defaultSyncDaysBack`/`defaultSyncDaysForward` in `MirrorConfig.swift` (Mac: `@AppStorage` defaults, the `SettingsPayload` decode fallback and the Preferences placeholders; iOS: fixed in `RouteStore`). Mac's background auto-sync reads the live `daysBack`/`daysForward` `@AppStorage` keys rather than the saved `settings.v2` blob, because nothing re-saves the blob when only a *default* moves — the blob can hold the old default while the UI uses the new one. Both apps now write by default (Mac's `writeEnabled` starts `true`; the Dry Run toolbar switch remains, chiefly for manual-selection mode); the **CLI** must stay dry-run unless `--write 1` is passed, so `--write` defaults to `false` explicitly — don't make it follow `writeEnabled` again, or scripted runs would start writing.
- **Placeholder title:** Mac configurable, iOS the constant `"Busy"` in `RouteStore`.
- **iOS hardcodes** `filterByWorkHours: false`, `mirrorAcceptedOnly: false`, `autoDeleteMissing: true` in `RouteStore.run`.
- **No server-side "Private" flag exists or can:** EventKit's public headers have nothing for privacy/classification. A "Mark Private" feature was built on an Objective-C runtime hack, never worked reliably, and was removed in 1.5.0 (it would also have blocked App Store review). Don't reintroduce it.

## Build and Release Commands

### Makefile targets (macOS)

```bash
make build-debug      # Debug build via xcodebuild
make build-release    # Release build via xcodebuild
make sign-app         # Sign the Release app with the Developer ID cert (strip xattr, codesign)
make notarize         # sign-app, then submit to Apple's notary service and staple the ticket
make package          # notarize, then create BusyMirror-<version>-macOS.zip + .sha256
make app              # Verify signed app exists
make clean            # Clean derived data
```

Signing happens in a `/tmp` scratch dir, not in-repo — this repo lives under iCloud Drive, which tags freshly written files with `com.apple.FinderInfo` before `codesign` can see it, and `codesign` refuses to sign a bundle carrying that xattr.

Built products:
- Unsigned release: `build/DerivedData/Build/Products/Release/BusyMirror.app`
- Signed + notarized: zipped as `BusyMirror-<version>-macOS.zip` at the repo root

### CI (macOS releases)

`.github/workflows/release.yml` triggers on pushing a `v*` tag: runs the unit test suite, then reuses this same `make package` (with `SIGN_IDENTITY`/`NOTARY_PROFILE` overridden for the ephemeral CI keychain) so the CI build path matches the local one exactly. Signs by certificate SHA-1, not common name — `codesign` can fail to match `Developer ID Application: TOMÁŠ KRÁČMAR` by string on some locales/encodings (an NFC/NFD Unicode normalization mismatch, hit for real running this by hand), so the workflow resolves the identity hash after import instead. Needs 5 repo secrets (`MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8_BASE64`) to actually notarize — without them it'll fail at signing/notarization, which is expected until they're added in repo Settings → Secrets and variables → Actions. Creates a GitHub Release with the zip attached on success. iOS isn't in this pipeline — TestFlight distribution is manual via Xcode Organizer.

### Xcode

macOS: open `BusyMirror.xcodeproj`, scheme **BusyMirror** → **My Mac**, **Product → Build** (or **Archive** for distribution).

iOS: scheme **BusyMirroriOS**, destination = a real device (no simulator runtime on this machine) or **Any iOS Device (arm64)** for archiving. See the `xcodebuild` command in "iOS/iPadOS target" above for a signing-free CLI build.

### Versioning

macOS and iOS version **independently** — separate `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` per target in `project.pbxproj`, separate `CHANGELOG.md` entries (iOS entries tagged `[iOS x.y.z]`; unmarked entries are macOS). Different maturity levels and feature surfaces (CLI/launchd don't exist on iOS; App Intents/BGTask don't exist on Mac), and App Store Connect itself tracks iOS/macOS builds independently even under one app record — no platform reason to force them to match. The Makefile's `VERSION` extraction (`sed` on `project.pbxproj` for the first `MARKETING_VERSION` match, used for ZIP naming) relies on the Mac target's entries appearing before the iOS target's in the file — true today, but worth a sanity check (`grep -n MARKETING_VERSION BusyMirror.xcodeproj/project.pbxproj`) if that ever seems wrong after a project-file reshuffle. Update both Debug and Release build configurations when bumping either platform's version.

## Code Style Guidelines

- **Language:** all code, comments, and user-facing strings are in **English**.
- **Concurrency:** `@MainActor` is required on methods that mutate SwiftUI `@State` or call EventKit on the main thread. The compiler enforces strict concurrency.
- **Formatting:** standard Swift style (4-space indentation). No external linter is configured.
- **Logging:** use the `log(_:)` method inside `ContentView`; it appends to both the on-screen log editor and the persistent file log (`~/Library/Logs/BusyMirror/BusyMirror.log`).
- **Error handling:** EventKit errors are caught and logged; they must never crash the app. The file logger swallows its own errors silently.

## Testing

- Unit tests exist in `BusyMirrorTests/` for `BlockMath`, `EventFilters`, `MirrorUtils`, `SettingsPayload`, `PlannedChange`/`PrefixMode`, and `Route` JSON coding (82 tests total) — these cover code shared with iOS too, since the source files are the same. Run: `xcodebuild -project BusyMirror.xcodeproj -scheme BusyMirror -destination 'platform=macOS' -only-testing:BusyMirrorTests test`.
- When adding logic, prefer extracting pure functions (e.g., block merging, gap calculation, filter logic, mirror detection) so they can be unit-tested — this is also what keeps a function usable from both targets.
- Manual testing checklist for macOS releases:
  1. Grant Calendar permission.
  2. Select a source and target, run DRY-RUN, verify log output.
  3. Toggle WRITE and run Mirror Now; verify placeholders appear in the target calendar.
  4. Move a source event and re-run; verify the placeholder updates.
  5. Test Cleanup Placeholders (dry-run and write).
  6. Add a route, install a schedule, verify the LaunchAgent plist is created in `~/Library/LaunchAgents/`.
  7. Trigger a menu-bar sync and confirm the window opens if not visible.
- Manual testing checklist for iOS/iPadOS (no simulator runtime on this machine — use a real device via `xcodebuild ... -destination 'platform=iOS,id=<UDID>'`, `xcrun devicectl list devices` to find the UDID):
  1. Grant Calendar permission on first launch.
  2. Add a route, run it manually, verify the placeholder appears.
  3. Run a Shortcuts action (run route / run all / status) and confirm it matches in-app behavior.
  4. Test Clean Up Placeholders and Sync All.
  5. For chained-mirroring changes: verify both the Privacy-off (verbatim relay) and Privacy-on (prefix-preserved via marker) paths.

## Security and Privacy Considerations

- **Calendar data:** both apps read and write the user's calendars via EventKit. Must handle permission denial gracefully.
- **Sandbox (macOS):** the app uses the macOS app sandbox (`com.apple.security.app-sandbox`) and the `com.apple.security.personal-information.calendars` entitlement.
- **Signing:** macOS releases are Developer ID signed and notarized (`make package`, since 1.10.0) — no more ad-hoc/Gatekeeper workaround needed. iOS builds are automatically signed for TestFlight/device installs.
- **Loop guard:** a `sessionGuard` set prevents mirroring an event into the same target twice in one run. Cross-mirror detection is primarily via the `mirror://...` URL tag every mirror event carries (`MirrorUtils.swift`), not the title prefix — the URL check is prefix/app/device-independent, which is what makes chained mirroring across the Mac/iOS boundary reliable. Title-prefix matching is a secondary fallback only.
- **Logging:** log files are written to the user's `~/Library/Logs/BusyMirror/` (macOS) or the app's container (iOS). No log data is transmitted externally.

## CLI and Scheduling

The binary supports headless execution:

```bash
# Run saved routes (used by the LaunchAgent)
BusyMirror.app/Contents/MacOS/BusyMirror --run-saved-routes --write 1 --exit

# Manual route via 1-based UI indices
BusyMirror.app/Contents/MacOS/BusyMirror --routes "1->2,3" --write 1 --exit
```

Relevant flags: `--privacy`, `--copy-notes`, `--sync-reminders`, `--all-day`, `--days-forward`, `--days-back`, `--merge-gap-hours`, `--mode`, `--exclude-titles`, `--exclude-organizers`, `--cleanup-only`, `--exit`.

Diagnostic/query flags (no calendar write, exit immediately): `--help`/`-h`, `--list-calendars [--json]`, `--status [--json]`. `--status` reads `lastRunAtISO`/`lastRunOK`/`lastRunSummary` in `UserDefaults`, written by `recordRunResult(ok:summary:)` at the end of every `--routes`/`--run-saved-routes` invocation. Exit codes: `2` = no calendar access, `3` = `--run-saved-routes` with no saved routes.

Scheduled runs are implemented by generating a `launchd` plist in `~/Library/LaunchAgents/com.cqrenet.BusyMirror.saved-routes.plist` and bootstrapping it with `launchctl`. The app removes and re-bootstraps the agent on every "Install Schedule" click.

## Key Files to Know

| File | Purpose |
|------|---------|
| `BusyMirror/ContentView.swift` | UI, settings, CLI, scheduling |
| `BusyMirror/MirrorEngine.swift` | EventKit mirror engine (runMirror, runCleanup, index persistence) |
| `BusyMirror/MirrorConfig.swift` | Configuration struct for mirror runs |
| `BusyMirror/MirrorUtils.swift` | Mirror URL builders, event detection, calendar labels |
| `BusyMirror/BlockMath.swift` | Block merging, gap calculation, overlap logic |
| `BusyMirror/EventFilters.swift` | Work-hours, title, and organizer filters |
| `BusyMirror/BusyMirrorApp.swift` | App struct, window scene, menu-bar extra |
| `BusyMirror/MenuBarSupport.swift` | `@MainActor` app controller + menu bar SwiftUI view |
| `BusyMirror/AppLogStore.swift` | File-backed log with rotation (`~/Library/Logs/BusyMirror/`) |
| `BusyMirror/Info.plist` | calendar/reminders usage descriptions |
| `BusyMirror/BusyMirror.entitlements` | Sandbox + calendar entitlement |
| `BusyMirroriOS/ContentView.swift` | iOS UI — routes list, Sync All, Cleanup, Settings sheet |
| `BusyMirroriOS/RouteStore.swift` | iOS route persistence/run logic, shared by UI and App Intents |
| `BusyMirroriOS/RouteIntents.swift` | Shortcuts/Siri App Intents |
| `Makefile` | Reproducible macOS build, sign, notarize, and package targets |
| `CHANGELOG.md` | Release notes (human-readable); iOS entries tagged `[iOS x.y.z]` |
| `ROADMAP.md` | Planned features and detailed feature-history notes for both platforms |

## Notes for Agents

- Do **not** add third-party dependencies unless the user explicitly asks. The project intentionally has zero external packages.
- If you refactor `ContentView.swift` (either target), preserve `@AppStorage`/`UserDefaults` keys exactly; users have existing settings on disk.
- The mirror engine (`MirrorEngine.swift`) is `@MainActor` and accepts an `EKEventStore` plus a logging closure. It does not directly mutate SwiftUI `@State`; the calling view/store manages all view state.
- A change to a file shared between targets (see "iOS/iPadOS target" above for the list) must build and test clean on **both** — check `BusyMirroriOS` with the `xcodebuild ... -sdk iphoneos CODE_SIGNING_ALLOWED=NO build` command above in addition to the Mac build/tests.
- When modifying build settings, update both Debug and Release configurations in `project.pbxproj`, and record any user-visible change in `CHANGELOG.md` under `## [Unreleased]` (a release renames that heading and bumps the version). Remember macOS and iOS version independently (see "Versioning" above) — don't bump one just because the other changed.
- Do not run `git commit`, `git push`, or similar operations unless explicitly asked.

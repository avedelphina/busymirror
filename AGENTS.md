# BusyMirror — Agent Reference

> This file is written for AI coding agents. It assumes you know nothing about the project.

## Project Overview

**BusyMirror** is a macOS menu-bar utility that mirrors calendar events from a source calendar into one or more target calendars, creating busy-placeholder events so availability stays consistent across accounts and devices.

It is a single-platform macOS app written in **Swift 5** and **SwiftUI**, using **EventKit** to read and write calendar data. The app runs as a menu-bar-only app (`LSUIElement`) with no Dock icon.

Key capabilities:
- Manual or route-driven multi-source mirroring
- Privacy mode: hide details (placeholder title)
- DRY-RUN mode to preview changes without writing
- Scheduled headless runs via a self-installed `launchd` LaunchAgent
- Settings autosave/restore, plus Import/Export JSON
- CLI support for headless/scripted runs

## Technology Stack

| Layer | Technology |
|-------|------------|
| Language | Swift 5.0 |
| UI Framework | SwiftUI + AppKit (menu bar, panels) |
| Calendar API | EventKit (`EKEventStore`, `EKEvent`, `EKCalendar`) |
| Persistence | `UserDefaults` (JSON-encoded settings), `@AppStorage` |
| Scheduling | `launchd` / `launchctl` (user LaunchAgent) |
| Build System | Xcode project (`BusyMirror.xcodeproj`) + Makefile |
| Target OS | macOS 15.5+ |
| Signing | Ad-hoc (`CODE_SIGN_IDENTITY = "-"`) — not notarized |

No external Swift Package Manager dependencies are used. The project is self-contained.

## Project Structure

```
BusyMirror/
├── BusyMirrorApp.swift          # App entry point; defines Window + MenuBarExtra
├── ContentView.swift            # Main UI, settings, CLI, scheduling (≈1800 lines)
├── MirrorEngine.swift           # EventKit mirror engine (read, deduplicate, merge, create/update/delete)
├── MirrorConfig.swift           # Configuration struct passed to the engine
├── MirrorUtils.swift            # URL builders, mirror detection, calendar labels
├── BlockMath.swift              # Block merging, gap calculation, overlap logic
├── EventFilters.swift           # Work-hours, title, and organizer filters
├── MenuBarSupport.swift         # `BusyMirrorAppController` (state coordinator) + menu bar view
├── Info.plist                   # LSUIElement, calendar usage descriptions
├── BusyMirror.entitlements      # App sandbox + calendar access entitlement
└── Assets.xcassets/             # AppIcon set and accent color

BusyMirror.xcodeproj/            # Xcode project
BusyMirrorTests/                 # Empty (no tests implemented)
BusyMirrorUITests/               # Empty (no tests implemented)
```

**Architecture note:** `ContentView.swift` handles the SwiftUI view hierarchy, settings serialization, CLI argument parsing, `launchd` scheduling, and logging. The EventKit mirror engine lives in `MirrorEngine.swift` and is invoked from `ContentView` via `makeEngine()`. Pure helper logic (block math, filters, URL utilities) has been extracted into standalone files for testability.

When making changes, keep the existing data flow (`@EnvironmentObject`, `@AppStorage`, `@State`) intact in `ContentView.swift`.

## Build and Release Commands

### Makefile targets

```bash
make build-debug      # Debug build via xcodebuild
make build-release    # Release build via xcodebuild
make sign-app         # Ad-hoc sign the Release app (strip xattr, codesign)
make app              # Verify signed app exists
make package          # Create BusyMirror-<version>-macOS.zip + .sha256
make clean            # Clean derived data
```

Built products:
- Unsigned release: `build/DerivedData/Build/Products/Release/BusyMirror.app`
- Signed release: `build/ReleaseSigned/BusyMirror.app`

### Xcode

1. Open `BusyMirror.xcodeproj`.
2. Select **BusyMirror** scheme → **My Mac**.
3. **Product → Build** (or **Archive** for distribution).

### Versioning

- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `project.pbxproj`.
- The Makefile extracts `MARKETING_VERSION` automatically for ZIP naming.
- Update both Debug and Release build configurations when bumping the version.

## Code Style Guidelines

- **Language:** all code, comments, and user-facing strings are in **English**.
- **Concurrency:** `@MainActor` is required on methods that mutate SwiftUI `@State` or call EventKit on the main thread. The compiler enforces strict concurrency.
- **Formatting:** standard Swift style (4-space indentation). No external linter is configured.
- **Logging:** use the `log(_:)` method inside `ContentView`; it appends to both the on-screen log editor and the persistent file log (`~/Library/Logs/BusyMirror/BusyMirror.log`).
- **Error handling:** EventKit errors are caught and logged; they must never crash the app. The file logger swallows its own errors silently.

## Testing

- Unit tests exist in `BusyMirrorTests/` for `BlockMath`, `EventFilters`, and `MirrorUtils`.
- When adding logic, prefer extracting pure functions (e.g., block merging, gap calculation, filter logic) so they can be unit-tested.
- Manual testing checklist for releases:
  1. Grant Calendar permission.
  2. Select a source and target, run DRY-RUN, verify log output.
  3. Toggle WRITE and run Mirror Now; verify placeholders appear in the target calendar.
  4. Move a source event and re-run; verify the placeholder updates.
  5. Test Cleanup Placeholders (dry-run and write).
  6. Add a route, install a schedule, verify the LaunchAgent plist is created in `~/Library/LaunchAgents/`.
  7. Trigger a menu-bar sync and confirm the window opens if not visible.

## Security and Privacy Considerations

- **Calendar data:** the app reads and writes the user’s calendars via EventKit. It must handle permission denial gracefully.
- **Sandbox:** the app uses the macOS app sandbox (`com.apple.security.app-sandbox`) and the `com.apple.security.personal-information.calendars` entitlement.
- **Signing:** releases are ad-hoc signed only (`codesign --sign -`). They are **not notarized**. Gatekeeper may block the app on first launch; users may need to right-click → Open.
- **Loop guard:** a `sessionGuard` set prevents mirroring an event into the same target twice in one run, and prefix-based detection (`titlePrefix`) prevents re-mirroring already-mirrored placeholders.
- **Logging:** log files are written to the user’s `~/Library/Logs/BusyMirror/`. No log data is transmitted externally.

## CLI and Scheduling

The binary supports headless execution:

```bash
# Run saved routes (used by the LaunchAgent)
BusyMirror.app/Contents/MacOS/BusyMirror --run-saved-routes --write 1 --exit

# Manual route via 1-based UI indices
BusyMirror.app/Contents/MacOS/BusyMirror --routes "1->2,3" --write 1 --exit
```

Relevant flags: `--privacy`, `--copy-notes`, `--all-day`, `--days-forward`, `--days-back`, `--merge-gap-hours`, `--mode`, `--exclude-titles`, `--exclude-organizers`, `--cleanup-only`, `--exit`.

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
| `BusyMirror/Info.plist` | `LSUIElement`, calendar usage descriptions |
| `BusyMirror/BusyMirror.entitlements` | Sandbox + calendar entitlement |
| `Makefile` | Reproducible build, sign, and package targets |
| `CHANGELOG.md` | Release notes (human-readable) |
| `ROADMAP.md` | Planned features |

## Notes for Agents

- Do **not** add third-party dependencies unless the user explicitly asks. The project intentionally has zero external packages.
- If you refactor `ContentView.swift`, preserve `@AppStorage` keys and `UserDefaults` keys exactly; users have existing settings on disk.
- The mirror engine (`MirrorEngine.swift`) is `@MainActor` and accepts an `EKEventStore` plus a logging closure. It does not directly mutate SwiftUI `@State`; `ContentView` manages all view state.
- When modifying build settings, update both Debug and Release configurations in `project.pbxproj`, and update `CHANGELOG.md` if the change is user-visible.
- Do not run `git commit`, `git push`, or similar operations unless explicitly asked.

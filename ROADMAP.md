# BusyMirror Roadmap

## Shipped (highlights)
- Route-driven mirroring (multi-source)
- Accepted-only filter (mirror your accepted meetings)
- Persistent settings with autosave/restore; Import/Export JSON
- Overlap modes (allow, skipCovered, fillGaps) and merge-gap
- Work Hours filter and title-based skip filters
- Privacy: placeholders with prefix + customizable title
- 1.3.0: Mark Private option (global + per-route)

## Next
- Auto-refresh calendars on `EKEventStoreChanged` (live refresh button-less)
- Hint near "Mirror Now" indicating run mode (Routes vs Manual)
- Better server-side privacy mapping (per-provider heuristics)

## Then
- Signed/notarized binaries and release pipeline
- CLI quality: friendlier `--routes` parsing and help flag
- “Dry-run by default” preference

## Later
- Background monitoring (macOS)
- Smarter cleanup & conflict resolution
- iOS/iPadOS helper (Shortcuts integration)
- Profiles & MDM/Managed Config support

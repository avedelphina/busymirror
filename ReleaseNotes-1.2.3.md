# BusyMirror 1.2.3 — 2025-10-10

This release focuses on reliable settings persistence and quality-of-life fixes from the 1.2.1 hotfix.

Highlights
- Settings persist between runs: autosave key options on change; restore on launch.
- Source/Target selection is remembered using calendar IDs and rehydrated into UI indices.

Fixes and improvements
- Save on change for: days back/forward, default merge gap, privacy/copy notes, all-day, accepted-only, overlap mode, title/placeholder prefixes, auto-delete.
- Restore saved `selectedSourceID` and `selectedTargetIDs` and rebuild index selections.
- Keep backward compatibility with older saved payloads.
- Version bump to 1.2.3 (build 5).

Included from 1.2.1
- Reinitialize `EKEventStore` after permission grant to avoid “Loaded 0 calendars”.
- Use attendee `participantStatus == .accepted` for accepted-only filter.
- Mark `requestAccess()` and `reloadCalendars()` as `@MainActor`.
- Makefile for reproducible builds and packaging.

Build
- `make build-release`
- `make package` → BusyMirror-1.2.3-macOS.zip and .sha256


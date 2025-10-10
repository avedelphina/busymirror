# Changelog
# Changelog

All notable changes to BusyMirror will be documented in this file.

## [1.2.4] - 2025-10-10
- Fix: enable “Mirror Now” when Routes are defined even if no Source/Targets are checked in the main window. Button now enables if either routes exist or a manual selection is present.

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

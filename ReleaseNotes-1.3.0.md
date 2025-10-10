# BusyMirror 1.3.0 — 2025-10-10

New
- Mark Private option: mirror events with your prefix + real title while marking them Private on supported servers (e.g., Exchange). Co‑workers see the time block but not the details.
- Per-route and global toggles for Mark Private; persists in settings and export/import.

Fixes & improvements
- More reliable calendar loading after permission grant (reinit EKEventStore).
- Concurrency: `@MainActor` on permission/refresh methods.
- Accepted‑only filter via current user attendee `participantStatus`.
- Settings autosave and restore (including source/target selections by IDs).
- Mirror Now enabled when calendars available; routes or manual selection used as appropriate.

Build
- `make build-release`
- `make package` → BusyMirror-1.3.0-macOS.zip and .sha256


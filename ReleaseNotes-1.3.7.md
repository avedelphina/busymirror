BusyMirror 1.3.7 - 2026-03-24

Changes
- Fix mirrored event tracking on providers that do not preserve BusyMirror's custom event URL metadata.
- Track source events using stable EventKit identifiers and a local mirror index so moved and deleted source events update target calendars reliably.
- Detect title and notes changes during reconciliation instead of only updating mirrors when times change.

Build
- Version bump to 1.3.7 (build 15).

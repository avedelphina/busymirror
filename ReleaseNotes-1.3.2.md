BusyMirror 1.3.2 — 2025-10-13

Changes
- Organizer filters: skip mirroring events whose organizer matches a name, email, or URL token. Case-insensitive. Configure in Options.
- CLI flags: `--exclude-organizers` and `--exclude-titles` accept comma/newline separated tokens. Example:
  - `--routes "1->2" --write 1 --exclude-organizers "alice@example.com, Example Org" --exit`

Notes
- Export/Import settings now includes organizer filters (backwards compatible).
- No changes to event URL format; feature is fully optional.


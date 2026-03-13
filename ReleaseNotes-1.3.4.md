BusyMirror 1.3.4 - 2026-03-13

Changes
- Fix multi-route cleanup so one source route no longer deletes mirrored placeholders created by another route.
- Persist activity logs to `~/Library/Logs/BusyMirror/BusyMirror.log` and expose a `Reveal Log File` action in the app.
- Add `--run-saved-routes` for headless runs using the routes configured in the UI, which makes `launchd` scheduling practical.
- Improve calendar refresh by pruning stale saved identifiers and recreating the EventKit store.
- Keep the left column from stretching to match the routes/log column on desktop layouts.

Build
- Version bump to 1.3.4 (build 12).

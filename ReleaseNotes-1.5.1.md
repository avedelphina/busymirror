# BusyMirror 1.5.1

## Bug fixes

- **Mirror index written on every sync** — `MirrorRecord`'s synthesized equality check included an `updatedAt` timestamp that is always set to the current date when a record is constructed. This meant every sync run marked the index as dirty and rewrote it to `UserDefaults`, even when no mirror events changed. Fixed with a custom `==` that ignores `updatedAt`.

- **Mirror URLs corrupted by special characters in calendar IDs** — Calendar and source IDs placed into the `mirror://` URL were not percent-encoded before joining with `;`. An ID containing `;` would cause the URL to be mis-parsed on the next sync, potentially losing the link between a placeholder and its source event. IDs are now encoded with `mirrorURLComponentEncode` (already present and tested since 1.4.0) and the URL path is assigned via `percentEncodedPath` to prevent double-encoding.

- **Calendar picker jumped during route cleanup** — Running "Cleanup Placeholders" over saved routes changed the source/target picker selection for each route. Cleanup no longer mutates the UI selection.

- **`--exit` flag was always implied** — Using `--routes` or `--run-saved-routes` always terminated the app, making `--exit` redundant. The app now exits only when `--exit` is explicitly passed.

## Improvements

- **Live calendar refresh** — The calendar list now updates automatically when the system calendar database changes (new account added, calendar renamed, etc.), without requiring a manual "Refresh Calendars" press.

- `AppLogStore` extracted into its own file; deprecated `FileHandle` API replaced with the modern throwing variant.

- `Block.span(start:end:)` convenience factory added to `BlockMath`, eliminating repetitive nil-field construction.

- Redundant `MainActor.run {}` wrappers removed from `MirrorEngine` (already running on `@MainActor`).

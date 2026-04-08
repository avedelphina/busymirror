BusyMirror 1.3.8 - 2026-04-08

Changes
- Fix release packaging so the ZIP contains `BusyMirror.app` at the archive root.
- Apply an ad-hoc bundle signature before packaging so the distributed app bundle verifies correctly after unzip.
- Strip resource fork sidecars from release archives to avoid malformed download contents.

Build
- Version bump to 1.3.8 (build 16).

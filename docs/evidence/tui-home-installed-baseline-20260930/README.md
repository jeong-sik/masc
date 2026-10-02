# Installed baseline provenance

The read-only identity check found an installed macOS arm64 TUI at version
0.49.0, source c112b2030652a5a25360f5d5322f8dc6da99c598. Commands and
checksum are in the manifest. The commands exited without opening a terminal
session; existing active sessions were not changed.

This binary precedes the Home integration. It is a candidate for the before
observation, not evidence that the new journey is installed or working.
A matching macOS candidate artifact, isolated fixture verification, and actual
operator observation are required before comparing the two versions.

The installed binary was then launched in its own synthetic-fixture PTY using
the integration checkout's Python harness. Three fresh frames at 80×24,120×32,
and160×48 were captured; navigation sent no decision POST. These frames show
the legacy Dashboard's Goal, Work, Usage, and attention summaries together.
The process exited and restored termios; active TUI sessions were not touched.

`frame-manifest.json` records raw hashes and Chromium/xterm capture geometry.
`frames.json` and `replay-baseline.py` reproduce the screenshots. Frame capture
is an installed-baseline observation, while PNGs are browser replays of those
bytes. This does not establish actual user performance or production data.

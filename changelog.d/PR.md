### Added

- `test_browser_lane` gains a viewport-cadence skip case: a settled cadence screenshot decodes to the exact record the TUI redraw skip compares (source, client, tab, title, url, viewport), an identical re-read decodes equal on every compared field, and a changed title, url or viewport already decodes different — so the skip holds only for a genuinely static page. Also pins that the armed cadence keeps naming the settled tab and that a busy view arms no cadence at all. Covers the unit gap left by the runtime-only verification of the #46832 redraw skip. (#PR)

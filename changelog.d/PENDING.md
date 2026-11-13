### Fixed

- `test_tui_browser_lane` expects a tap on an ego connection to be sent. Ego
  serves touch since #49295, and the test still expected the tap to be refused,
  so it raised in its pointer case and the fifteen cases after it never ran.
  The test now runs every case and reports each one that fails before it exits
  with a failure (#51638).

### Changed

- An Execute command's outcome line spells its run time and limit like the
  rest of the TUI (RFC tui-one-screen-grammar 6.2): `exit 0 · 808ms`,
  `signal 9 · 30.0s · timed out at 30s`, and `2m05s` for a long run. It
  read `30012 ms` and `timed out at 30 s` before.

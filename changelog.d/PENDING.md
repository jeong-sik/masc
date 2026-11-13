### Fixed

- `masc start` now refuses the boot with one `[FATAL]` sentence on stderr and
  exit 1 when it cannot create or open `<base path>/.masc/logs`. The sentence
  names the directory and the OS cause. The failure used to leave as an
  uncaught `Unix_error` with a backtrace and exit 125, which reads as a program
  error. `Log.Ring.init_file_sink` returns the failure as a value, so the TUI
  log store reports an undecodable log row as unavailable storage too (#51246).

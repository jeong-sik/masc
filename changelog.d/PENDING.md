### Fixed

- TUI: a bounded image subprocess now reports why it ended. `wait_bounded`,
  `run_bounded` and every image runner return `Exited`, `Killed_at_deadline`
  or `Cancelled` instead of one `WSIGNALED SIGKILL` for all three. Decoder,
  curl and Pele failures say "killed at its deadline" instead of guessing
  "out of time or memory", a SIGKILL from anyone else stays a signal, and an
  external image opener cancelled at exit no longer hands off to the next
  opener. The shutdown cancellation test now fails if cancellation stops
  working, rather than passing on the 30-second deadline (#52135).

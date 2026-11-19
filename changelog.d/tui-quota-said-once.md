### Fixed

- The TUI runtime table no longer says a spent account twice. A runtime
  resting for its provider quota (a quota refusal or a usage read that found
  the window spent) read `한도 소진 (…)` and then `계정 한도 소진` on the same
  row; the rest, which carries when it ends, now says it alone. A payment
  refusal still shows the account limit beside it.

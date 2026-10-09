# File history failure reproduction

Installed binary: `/Users/dancer/.local/bin/masc-tui`
Reported build commit: `132e8d8a23d7503275ff82142890586dba6e79c5`

Command: `python3 test/test_tui_code_history_sources_pty.py /Users/dancer/.local/bin/masc-tui`

Synthetic HTTP fixture, real PTY, 60 columns. Git log returns HTTP 503, while
the independently addressed Keeper history endpoint can return a valid change.
The installed TUI displays only `History unavailable: git log: HTTP 503` and
does not show the Keeper record. The scenario fails waiting for that record.
The final rendered frame is in `before-60.txt` (right-hand cell padding removed). No live Keeper work was invoked.

This is before-change evidence. The changed OCaml sources pass parsing, and
the Python scenarios pass syntax checks. No new binary was built or installed;
after-change PTY execution, type checking and CI remain unverified.

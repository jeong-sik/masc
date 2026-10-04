# Review response: nonlive owners and workspace read failures

The reviewed head was `5314d4ed7ea71f71577404997a06ce4dfa3faf78`.

Offline, Stopped, Crashed and Restarting now override a stale turn observation.
Running, Failing, Paused and Draining still show a retained executing turn.
The regression starts a real registry turn, changes the lifecycle without its
finish write, and checks the projected phase for all four nonlive states.

The TUI now consumes `global_waiting_on` alongside keeper-local rows. Both use
the same phase tally, so schedule/approval store failures remain visible as
unavailable even with no Keeper rows. An absent global inventory is a decode
error. The regression covers two global failures and a missing inventory.

Eight source/interface/test files passed isolated OCaml 5.5.1 type checks with
cached interfaces and warnings 8/32/69 treated as errors. Source hashes and
exit codes are in typecheck-results.json. These are type checks, not executed
behavioral tests, a full build, or PTY/production evidence. The earlier evidence
remains scoped to its original source hashes.

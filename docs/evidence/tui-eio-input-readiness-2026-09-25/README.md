# TUI input readiness on the owner fiber

## Observation

The integrated candidate2 comparison in [PR #38873](https://github.com/jeong-sik/masc/pull/38873)
(run 36032545600) observed 0.512542–136.217875ms input-to-completed-PTY-frame
latency despite 0.69–0.75ms frame-build p95. That evidence does not by itself
attribute the longer waits to a particular call site.

Source inspection found `read_input` wrapping the entire decoder in
`Eio_guard.run_in_systhread`, including buffered keys and deadline polls.
Consequently `terminal_has_bytes` always selects its non-Eio `Unix.select`
fallback there, even though it already implements an Eio readiness/timer
race. TUI startup installs both the Eio clock and network context.

## Change and ownership

Replace that wrapper with the existing named-switch helper. The input reader
stays on its caller fiber and waits through the existing Eio path. A named
switch retains trace attribution without a system-thread hop. The startup
terminal probe keeps its explicit blocking-thread boundary.

Only readiness races the timer. The consuming `Unix.read` runs after the
winner returns, so cancelling a losing readiness wait does not consume and
lose a keystroke. Buffered/replayed input, UTF-8 state, CSI grammar, paste
handling and frame policy are otherwise handled by their existing code.

## Focused behavioral coverage

`test_tui_input_readiness_pty.py` reuses the real PTY harness and existing
exact-message-byte checks for Unicode/malformed sequences and bracketed
paste. A new fragmented-Unicode scenario requires a complete resized frame
between the prefix and continuation, proving the loop progressed while a
scalar was incomplete. Another sends SIGTERM with a pending scalar and
requires clean exit plus restoration of the original terminal mode.

Python syntax, OCaml formatting and diff checks pass. No local OCaml build
or candidate behavior execution has been performed. Focused CI and an exact
binary comparison are still required. Existing scalar/CSI/probe/signal suites
cover additional parsing transitions.

## Limits and next measurement

This removes an unnecessary dispatch boundary. It is not yet evidence that
system-thread dispatch caused the observed 22–136ms waits, or that the
0.1ms target is achieved. The latest input pacing still imposes a 16ms
interval on successive input frames. Compare candidate2 against an otherwise
identical candidate with only this source change before attributing latency
improvement. No production deployment or restart is part of this slice.

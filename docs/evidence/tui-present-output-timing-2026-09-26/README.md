# Attributing slow terminal presentations

The retained-tab experiment in PR #39263, run
[`36238470111`](https://github.com/jeong-sik/masc/actions/runs/36238470111),
recorded candidate whole-session `present[keeper-detail]` maxima of 24.91,
121.97 and 165.06ms. Those summaries include untimed setup and do not identify
which input caused each slow presentation. They cannot establish whether
diff construction or terminal output occupied that time.

## Observation change

The existing `MASC_TUI_FRAME_TIMING` report now attaches write/flush elapsed
times, byte counts and call counts to the same Present sample as its ordinal,
surface and total. The five worst Present lines retain those fields together
when sorted. Unchanged frames retain zero calls and bytes. The recording path
does not save terminal text, send additional terminal output, or change the
output order. Reporting still happens at exit. Without timing enabled, the
original callbacks pass through directly.

`other` is total Present time minus the two measured callback durations. It
includes diff construction and other work outside those callbacks, plus any
GC, scheduling delay and instrumentation overhead there. It is not a CPU
measurement. Both `output_string` and `flush` may send buffered bytes; see the
[OCaml channel documentation](https://ocaml.org/manual/5.5/api/Out_channel.html).
Attributing wall time to either callback does not establish why it waited or
when a physical display finished painting.

Build and Present remain separate. Window-title output precedes Present and
is outside this accounting, as before. Raising presentations do not yield
samples, matching the existing timing wrapper. The report is not an input
trace and still cannot associate a frame ordinal with a specific keypress.

## Verification

- Deterministic summary cases interleave Build, emitted Present, unchanged
  Present and another emitted Present, with distinct counts and durations.
  Sorting must retain each frame's own output data and ordinal.
- Callback checks retain the return value, write/flush ordering, no-op
  behavior and output exception propagation.
- `test_tui_present_timing_pty.py` starts a real TUI against synthetic HTTP and
  workspace data, moves the Keeper selection, exits normally and inspects the
  emitted timing report. It checks byte/call accounting and that components
  sum to the total within the report's decimal rounding. It sets no latency
  threshold and proves no performance improvement.

Local syntax and whitespace checks pass. No local OCaml build was run.
Compiled tests and the PTY scenario require CI on the pushed head. The old
165.06ms observation is the motivation, not evidence that this change has
identified its cause or achieved the 0.1ms response objective.

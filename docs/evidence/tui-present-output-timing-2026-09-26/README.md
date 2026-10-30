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
- The test stanza enables recording before module initialization. Callback
  checks retain the return value, write/flush ordering, no-op behavior and
  both write and flush exception propagation while recording is enabled.
- `test_tui_present_timing_pty.py` starts a real TUI against synthetic HTTP and
  workspace data, moves the Keeper selection, exits normally and inspects the
  emitted timing report. It checks byte/call accounting and that components
  sum to the total within the report's decimal rounding. It sets no latency
  threshold and proves no performance improvement.

Local syntax and whitespace checks pass. No local OCaml build was run.
Compiled tests and the PTY scenario require CI on the pushed head. The old
165.06ms observation is the motivation, not evidence that this change has
identified its cause or achieved the 0.1ms response objective.

## Local diagnostic observation

`local-diagnostic/` retains the raw receipts, stdout/stderr, internal timing,
identity, runner and recomputed aggregates. Runtime probe artifact `10905313235`
from [build 36239521218](https://github.com/jeong-sik/masc/actions/runs/36239521218)
identifies source `53f784617c1867b3ecadb300bc8bd1d0844dd233`, TUI SHA-256
`88b23dce786b5721e8ac1c5730b9735088141e6324af1e677d9d4ce92dee2bc8`.
The artifact archive digest and all three manifest binary hashes were checked.
The manifest explicitly has `release_validated: false`; no binary was installed.

The local macOS ARM probe ran three sessions against harness
`4d31a42ca9c948d9c1605625dd45c2b6c122d0a3`. Each has ten cycles, 100 acknowledged
transitions, a checked draft, and 250 retained synthetic Channels names. All
300 transitions and three draft checks passed. Metadata and channel-fixture
hashes match across sessions. The diagnostic binary is based on main and does
not include the separately reviewed drained-input/deferred-tab PRs, so its
17.1–17.4ms overall input medians are not a comparison with their earlier results.

| Session | Worst Present, ms | Write, ms | Flush, ms | Other, ms | Output bytes |
|---|---:|---:|---:|---:|---:|
| 1 | 25.37 | 0.001 | 25.365 | 0.004 | 2589 |
| 2 | 24.52 | 0.001 | 24.511 | 0.005 | 2589 |
| 3 | 22.03 | 0.001 | 22.024 | 0.005 | 2589 |

Each maximum is Present ordinal 79 on `keeper-detail`. Nearly all its measured
wall time is inside flush. This local observation directs the next diagnosis
toward output/consumer scheduling, rather than attributing this particular tail
to diff construction. It does not identify the OS-level cause of that wait,
correlate ordinal 79 with a specific input, or establish the cause of the older
165.06ms CI observation. There is no physical-display or deployed-runtime proof,
and the 0.1ms objective remains unmet.

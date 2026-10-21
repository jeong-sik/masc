# Original Ask follow-up source intervals

Follows #44730 on Native Stack #44156. This continues the original observation
and matched-comparison axis without replacing useful original Task work,
preparation, Composition, held-job/backend or actual TUI evidence requirements.

## As-Is / To-Be

| Boundary | Before | Source behavior after this change |
|---|---|---|
| Independently received sources | Raw `source_processed` rows are retained but skipped when computing stages. | Wake/turn, Tool-result and original-Task observations each retain receipt/processing clocks and artifact provenance. |
| Time attribution | Overall admission, producer and UI intervals only. | Each source also exposes admission-to-receipt, admission-to-processing and receipt-to-processing. No cross-process subtraction or new runtime clock. |
| Source handling | Applicator result visible only in raw JSON. | Unambiguous accepted and rejected events are counted separately. Acceptance does not certify a successful source or Task. |
| Missing/repeated source | No source coverage summary. | Unobserved and ambiguous reads remain in the full original denominator, with null intervals. All repeated facts remain; no first/latest event is selected. |
| Partial failure | Overall read outcome. | Valid source intervals remain independently visible after failed/cancelled/unfinished reads. Unstarted reads cannot invent source handling. |
| Contradictory evidence | Overall capsule/capture checks clear overall metrics. | Original source clocks must also fit any recorded worker/producer/UI endpoints. Both overall and source metrics are cleared on original/capture/clock contradictions. |
| Before/After | Overall descriptive means only. | Source coverage and exact-rational observed mean deltas use the same declared-condition and error checks, preserving separate observed/all counts. |

## Actual producer and consumers

Main stamps receipt in its original `observe_keeper_ask_followup` event callback
before publishing the workspace result. After the original UI request handler
returns a source applicator Result, `Masc_tui_ask_followup_observation.emit`
records `source_processed`, `received_ns`, `observed_ns` and `source_applied`.
The existing Log.Ring entry carries the original instance/request/admission
capsule. The offline reader validates that capsule and keeps the original
artifact/hash/line reference. Neither opaque source snapshots nor protocol
start/complete markers are reinterpreted as successful data-source reads.

Packet materialization consumes the same analyzer and retains its new JSON
fields. Markdown exposes each source's coverage and intervals. Each source
contributes at most one interval per original read; ambiguity withholds its
metrics while retaining raw facts. Known lifecycle contradictions invalidate
the attempt. A late capture contradiction also clears source metrics; retained
invalid facts never enter source means. Missing lifecycle endpoints stay unknown.

## Before/After evidence and limits

No matched real packet for this candidate is available. This is implementation
of the analysis path, not a generated comparison or a speedup measurement.
Comparable future arms require the same original declared conditions and full
known attempt rosters. Include failed/cancelled/withdrawn/not-started/unfinished/
unobserved attempts and partial source observations. Receipt-to-processing is
client queue/handler observation, not pure network/CPU time, paint or model work.
Independent source intervals can overlap and must not be summed as total latency.

New grouping, validation, source records and tables add offline CPU, memory and
serialization. No producer instrumentation, API call, worker, cap, timeout,
runtime prompt, live setting, authority or source-success decision changes.
Useful original Task effects/verification, installed runtime behavior, visible
TUI/input/paint and the full six-axis actual Before/After remain unverified.

The existing real two-workspace Ask/resource/Log.Ring/file/materializer/report
scenario now keeps source artifact provenance and corrupts a real receipt by
substituting its later UI-processing clock. The row still has locally ordered
clocks, but contradicts its actual producer-return endpoint; report admission
must fail and withhold source intervals. This authored extension is unexecuted.
Its identity comparison normalizes the existing JSON wire representation so an
OCaml Intlit versus parsed Int cannot replace the original clock identity check.
No helper-mirror, invocation-count, wording/layout/snapshot or PTY test is added.

Validation is Python AST parsing, OCaml parsing of the changed existing scenario,
source/consumer and whitespace inspection only. No report import/execution,
build/typecheck/test, CI dispatch/watch/poll, TUI/native/model/controller/audio/
PTY run, installation, restart, live write, own approval or merge is performed.

# Original admission-capture failure attribution

| Boundary | As-Is | To-Be in this source |
|---|---|---|
| Expected journal I/O failure | Startup warning with filesystem message and null details | Lazy structured Warn/Boundary with original origin/request/admission clock |
| Cost attribution | Admission intervals include preparation, no separate failed-capture span | Captured start/observed clocks for failed payload/append/error conversion |
| Local Logs detail | Unbound opaque warning | Existing ring/shared decoder/detail carry original structured diagnostic |
| Comparison | Ordinary warning ignored | Known attempt and capture facts retained separately from read outcome |

The store keeps its original Error result and does not authorize or stop the
original observation. It retains immutable provenance supplied by the caller;
current workspace/question state is never borrowed. The existing Startup Warn
policy, Boundary category, redaction, ring/file/console sinks and generic lazy
writer are reused. No new backend, retry, filter knob, actor or authority gate.
The formatter only formats already captured facts. Filesystem diagnostics are
retained, with no question/answer body added.

One clock is captured before every admission payload/append. On expected failure,
the end clock is captured after error conversion and before lazy logging. Failed
capture spans therefore include payload/append/lock/flush/error conversion and
exclude warning formatting/output. Happy-path writes add one clock and have no
new event/span. Original admission-to-start/worker/UI intervals still include all
preparation and logging costs. No CPU, Loading, input or latency gain is measured.

The strict reader validates the new event's exact fields, Warn/startup/boundary
channel, original provenance and clock order. It preserves raw failure facts,
artifact/line/row references, observed duration and summary counts. Shared log-row
identity prevents duplicate evidence; origins must agree with other observations
of the same original read. Invalid provenance invalidates comparison metrics.

Valid capture failure is an observation fact, not an evidence-format error or
producer/UI failure. It can coexist with a complete, failed or not-started read.
Warning-only attempts remain unobserved. Warnings never become independent
declared roster entries; missing declarations remain errors. A valid independent
denominator permits retaining failed-capture samples without excluding them from
comparison. Missing warnings and capture completeness remain unknown.

Two existing actual canonical Ask/answer/Task/frame/store cases are extended,
unexecuted. A real fresh admission-path directory blocker produces the diagnostic
before dispatch-not-started; restoring the file allows the next filtered admission,
and actual artifacts pass through public materializer/reader source. The failure
is retained separately from not-started outcome and original plan/journal counts.
Another actual blocked capture still permits read completion and decodes its
original diagnostic through the production local Logs adapter. Original Task
resources remain unchanged. No wording/layout/snapshot/PTY/helper-count tests.

Validation is OCaml parsing for three files (interface first), Python AST parsing
for one, and source/diff inspection. No consumer/import/CLI/test/build/typecheck,
CI, native/model/controller/audio/PTY run, install/restart/live write, delegation,
approval or merge. Actual UI paint/input, matched Before/After, full capture and
all six original objective axes remain unverified.

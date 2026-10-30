# Compare reported preparation intervals by original strategy

Source comparison base: `1ee65e2196ddfca533e9acf6c062fd3cc0c98bba`
(#43891). This unit changes the existing offline capture reader and its compound
filesystem/CLI scenario. No report, coordinator, native driver or test executes.

## As-Is / To-Be

The reader already retained all manifest-declared attempts and five exact
per-attempt counter intervals, including partial failed/unfinished receipts.
Its pair projection only reported common-input matched/mismatch/incomplete
status. Readers had to join arm timings themselves, and execution order
alternates: positional first-minus-second would reverse the meaning of a delta.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Per-arm intervals | Exact own-counter spans with unavailable reasons | Retained unchanged |
| Pair interval differences | Absent | Signed exact `exact_skill_minus_direct_ns` or explicit unavailability |
| Strategy orientation | Pair execution order alternates | Declared `direct` baseline and `exact_skill` comparison, independent of order |
| Failed/unfinished timing | Partial spans retained per attempt | Same spans can compare without declaring functional success |
| Missing/invalid/cancelled arm | Retained in attempt denominator | Also retained in pair arms with original reported outcome/read state/hash |
| Common input mismatch | Excluded from successful matching | Also blocks duration comparison without changing raw evidence |
| Both tool inventories unreported | Agreement with separate coverage flag | Existing matching semantics retained; no duration difference supplied |
| Counter ownership | Validate each span's own owner | Same validation plus distinct reported owners for paired difference |
| One unavailable endpoint/useful join | Per-attempt reason | Only that interval unavailable; other comparable spans survive |
| Execution/source/speedup verdict | False/false/null | Same unverified verdicts |

## Source and attribution

`reported_pair_timing` consumes only the already-derived `timing_report`
intervals. It indexes by the manifest's declared strategy, including an invalid
raw receipt that claimed another strategy: such a receipt remains unadmitted,
rather than borrowing the other arm. It uses the existing common-field mismatch
calculation once, now available even when the functional pair is incomplete.
Existing functional outcome assessments and `matching` membership are retained.

Pair blockers identify unadmitted receipts, common-input disagreement, case
different from the declared experiment, unreported fixture/tool-inventory/common
instruction hashes, missing owners or a shared reported counter owner. A hash
string's presence and receipt agreement are reported metadata, not proof of
authentic inventory or physical execution. Matching two failed receipts from
another case does not supply this declared experiment's comparison.

Each available difference subtracts **durations**, after each duration was
derived from exact endpoints belonging to its own driver counter. It never
subtracts absolute timestamps across owners or wall-clock fields. Signed decimal
integer strings preserve large values and zero without float rounding, division,
ratio, arbitrary threshold or workload limit. Distinct owner tags are checked;
they do not prove two physically independent processes.

Useful-commit intervals still require the existing frozen fixture, original
Task/trace/turn, admission/intake and complete Tool-commit journal/selection join,
including the nominated commit within its reported cycle. A failed useful join
withholds that interval, while a separately available cycle can compare. The
existing metadata-only identity and execution limits remain; no semantic first
successful leaf, model identity, SDK execution or original Task completion is
inferred by the reader.

The normal coordinator and `--report-from` share this projection. The report
path remains read-only and returns before driver invocation. No native producer,
Runtime/tool scheduling, provider payload, retry, timeout, frame budget, source
build verification or performance claim changes. No public product enum changes;
the additive CLI report fields and reason data are documented in the harness
contract beside their producer.

## Quantitative Before / After limits

There were no pair interval deltas; the existing interval set now has one
available exact delta or explicit unavailable result per declared pair. This is
reporting coverage, not reduced preparation time. The manifest denominator and
every failed/cancelled/interrupted/unfinished attempt remain. Extra metadata
checks, integer subtraction and report bytes add unmeasured offline overhead;
there is no claim of runtime/CPU/memory savings, percentiles or speedup.

`direct` and `exact_skill` identify strategies within a declared experiment,
not arbitrary old/new source versions. Matched actual cohorts still require
their original source/build/runtime/Task evidence. A reported negative duration
difference does not establish a measured implementation improvement.

## Authored compound scenario, not executed

The existing offline source/Task/counter fixture is extended. It constructs real
temporary capture files, manifest and identity artifacts, then calls the actual
CLI report path when the scenario is eventually run. Controlled counter values
are fixtures, not measurements. No production predicate/helper is mirrored.

- Three complete declared pairs reverse strategy order, use different absolute
  counter origins and include positive, negative-above-float-precision and zero
  duration differences. All attempts report failure/unfinished; timing does not
  turn them into matching functional successes.
- Removing one validation endpoint keeps the independent cycle comparison.
  Foreign input, agreement on another case, two unreported inventories and a
  reused owner withhold comparisons while retaining individual evidence.
- Cancelled and then missing receipt states remain in the declared cohort with
  their original reported outcome or missing state. Every CLI read must leave
  file bytes/hashes and membership unchanged.
- Existing original Task/clock substitution, negative/legacy timestamp and
  missing Tool-commit evidence scenarios remain in the same fixture.

The scenario is authored and **unexecuted**. Only Python AST parsing and
diff/changelog hygiene are author checks; no module import, report execution,
coordinator/test/driver/native/model/PTY run, CI dispatch/watch, installation,
restart or live config write occurs. Parsing is not assertion success or an
independent source approval. The full six-part Ask/Task, preparation, Composition,
held/shared batches, input/visibility and matched actual evidence goal remains
open.

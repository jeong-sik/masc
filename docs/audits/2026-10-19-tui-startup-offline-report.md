# Compare supplied startup observations without selecting away missing work

Source comparison base: `15fd7e6489d2d40a227976db554e29781d47f99b` (#43800).
This is an offline report implementation, not an executed comparison or speed result.

## As-Is / To-Be

The source already emits typed probe/first-input lifecycle facts. Its existing
TUI timing scripts launch native PTY children, and the Keeper preparation
coordinator runs explicit runtime cycles. Neither consumes these existing
startup records into a matched report. Manual comparison can confuse log order
with event order, discard incomplete attempts or substitute zero for absent
Before instrumentation.

The new standard-library Python consumer reads an explicit versioned packet,
frozen candidate/log files and original capture selectors. It generates JSON or
Markdown without launching code, network work, a terminal, candidate or model.
Each supplied path is read once and each log digest indexed once per invocation.
Validated immutable records are reused, not immediately reparsed for every arm.

| Report boundary | Before | Source implementation |
| --- | --- | --- |
| Existing startup-record consumer | No dedicated offline consumer | One packet/record consumer |
| Denominator | No startup packet contract | Every declared case retained, including invalid metadata |
| Absent instrumentation/file/endpoint | No typed report | Missing or invalid evidence, never zero duration |
| Caller interruption plus late capture | Separate raw rows | Independent immutable caller/capture facts |
| Concurrent/out-of-order rows | Manual interpretation | Matching field facts; row order is not causal order |
| Duplicate/conflicting evidence | No report policy here | Invalid rows/facts or explicitly withheld reused-capture delta |
| Foreign capture errors | Shared artifact | Identifiable owners remain separate; unattributable corruption remains invalid |
| Metric evidence | Raw lifecycle records | Eight internal intervals and per-case After-minus-Before when eligible |
| Source/execution/paint/useful work | Not proved by these files | Still unverified |

This counts source capability, not executed samples. No actual Before/After,
runtime duration, installation or speed measurement accompanies the change.

## Packet and provenance

The packet lists the entire case denominator, expected condition declarations
and both arm declarations. Each arm names a source SHA or explicit unknown,
candidate bytes/log references, original PID/probe dispatch selector and its
own fixture/workspace/terminal/input-reply digests. Only the supplied file bytes
are hash-checked. Conditions and source are declarations; their execution and
source-to-binary binding are not independently certified by this tool.

Unknown packet/record schemas and ambiguous JSON members are refused. Invalid
individual cases remain rows in the declared denominator. Artifact absence,
digest mismatch, condition mismatch, corrupt rows and missing endpoints retain
their distinct evidence/basis fields. No healthy subset is promoted to the
whole cohort. A top-level packet that cannot be interpreted is an explicit
invalid-packet error, not an empty experiment.

Reusing the same nonempty artifact/capture selection across arms or cases
withholds its deltas. This catches literal evidence reuse, not unprovable
independence between differently packaged artifacts. Metadata checks never
promote into actual runtime/source verification. The report keeps those flags
false and `measured_speedup` null even when descriptive pairs are available.

## Records, clocks and non-success samples

The parser uses the actual Log.Ring envelope and exact Transport/INFO message
tag. It consumes the current producer's fields/discriminants, including
`handed_off` for decoder installation; it does not guess arbitrary stderr text.
Immutable caller, capture and first-input facts must agree. Latest capability
application uses its own timestamp and must retain first-answer availability.
No later row can overwrite caller interruption with capture success.

All raw nanosecond facts remain exact decimal strings in the report. Derived
intervals are checked against their endpoints within one original process and
capture. Negative/inconsistent intervals are invalid rather than clamped.
Cross-process monotonic timestamps are never subtracted. Missing endpoints stay
null. Failed/interrupted samples remain counted, including intervals that were
actually observed before failure. Input reception is not acceptance or paint.

Each metric reports its paired count against the full case denominator. JSON
retains all case outcomes and reasons; Markdown shows key internal intervals
and all evidence/caller/capture/input counts. No pooled percentile, favorable
performance threshold, success verdict or new runtime control is added.

The operation has full-file snapshots and JSON validation/indexing cost. Memory,
CPU and end-to-end report latency are unmeasured. A generated report and matching
hashes do not prove complete event delivery or the semantics of a recorded run.

## Authored evidence and limits

Four authored, unexecuted compound scenarios use explicit synthetic files and
the actual packet reader: full-denominator interrupted/late/absent attempts;
foreign owner isolation with corrupt/conflicting/duplicated rows and bad binary
identity; and Int64 precision with mismatched conditions, duplicate case IDs,
truncated data and capture reuse; and a healthy cohort with NUL/unencodable
artifact paths. The path boundary rejects NUL before filesystem access and
converts specific filesystem encoding errors to invalid artifact evidence,
retaining the full denominator and independently valid arms. They import no native TUI/OCaml runtime and
start no network, server, PTY or model. No wording/layout/snapshot assertions are
added. These fixtures are not measured benchmark results.

Source checks parse Python ASTs without importing/executing report or scenarios.
They do not prove assertions, typing, behavior, independent approval, merge,
native input, paint or speed. The full goal still requires original Task/Ask
and preparation/Composition continuity plus matched real observations retaining
failed, cancelled, interrupted and unfinished attempts. This report implements
only the startup-record comparison boundary.

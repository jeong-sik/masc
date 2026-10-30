# Original Ask follow-up: preserve recorded Tool outcomes

Comparison base: `5148428c29411eff4a10181b5df0432c9b67a30c` (#43926).
This is a source comparison, not an executed UI or performance result.

## As-Is / To-Be

The original canonical answer already selected exact physical Tool result rows.
Its observer counted failed rows, but exposed only a total, clocks and latest
execution/trace/turn/Tool identity. A failed result could therefore appear as
ordinary informational activity without exposing its outcome. Original Task,
turn/wake and Tool evidence already had independent read and retention paths.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Original physical result count | All admitted rows, including failed results | Same cohort and total, partitioned into five canonical outcome buckets |
| Outcome authority | Not projected in Ask follow-up | Existing `Tool_result.recorded_call_outcome`; typed disposition precedes wire outcome |
| Latest result | Original logical/physical/trace/turn/Tool/clock | Same identities plus canonical outcome |
| TUI feedback | Total and latest Tool/turn | Total, nonzero outcome distribution and latest outcome/Tool/turn |
| Diagnostic event | Identity, total and clocks | Same fields plus all five counts and latest outcome; no result bodies |
| Refresh failure or shrinking count | Retain earlier source, marked unconfirmed | Retain its counts and latest outcome under the same freshness state |
| Original Task | Independent original linked Task | Same independent state; Tool success/failure cannot advance it |

The five buckets are `succeeded`, `deferred`, `failed`, `unsettled` and
`malformed`, using the existing closed result type rather than a second enum.
Missing/unknown wire outcomes are unsettled; malformed outcome fields stay
malformed. These are observed results, not missing physical identities. Invalid
or duplicate physical identities still leave the whole Tool branch unavailable.
Typed completion can coexist with failed response delivery; typed deferral is
not replaced with a delivery failure. The central classifier is unchanged.

The opt-in aggregate and source-stream projections share the same serializer.
The decoder requires all five nonnegative counts, verifies their total by
subtraction without adding potentially overflowing wire integers, and requires
the latest result's bucket to be nonempty. Unknown latest tags and ambiguous
fields fail the protocol read instead of inventing success. Zero observations
require zero counts and no first/latest result under the existing clock rules.
Producer and consumer change together; no compatibility defaults are added.

The TUI retains its independent source readiness, exact immutable answer identity
and request-owner boundaries. It warns on failed/unsettled/malformed or retained
evidence and distinguishes a current failed latest result. Wrapping uses the
existing actual emitted-row viewport accounting. This is not visible paint,
readability, usable-input or latency evidence.

## Quantitative Before / After

Outcome categories exposed for each admitted physical result change from zero
to five, and the latest result gains one canonical outcome tag. Physical row
membership, total observations, Tool effects, Task transitions, provider calls
and HTTP request count do not change. Counts are accumulated in the existing
row fold; no extra ledger read, refresh job, cache, timer, cap or control gate is
added. All five wire/diagnostic counts remain explicit, including zero values.

The authored isolated-store scenario retains eight original physical results:
three succeeded, two failed, one deferred, one unsettled and one malformed.
Other-answer-time and other-Keeper rows are excluded; repeated logical nodes
with fresh physical IDs remain distinct. These are fixture expectations, not
measured results. The scenario also retains the original Todo Task and tests
reaction-read failure, duplicate physical evidence, shrink/rebuild and foreign
workspace refusal. Decoder/source-state scenarios add outcome partition,
latest-bucket, independent Done Task and stale retention assertions. They were
not executed. No layout, wording, row-order, snapshot, PTY, helper-mirror or
invocation-count test is added.

Latency, memory, throughput and useful-work improvement remain unmeasured.
Any later matched cohort must keep failed/cancelled/interrupted/unfinished
samples; these result buckets cannot recover unfinished Tool starts or native
actions without a committed physical result, and zero does not prove inactivity.

## Evidence scope and remaining work

Changed OCaml files are checked with parsing only. No build, typecheck, test,
CI dispatch/watch, native/model/PTY/controller/report run, install, restart,
live prompt/config write or own merge is performed. Source review, compilation,
runtime observation, actual Task progress and matched Before/After remain
separate boundaries. This bounded outcome projection addresses the original
Ask observation axis; preparation, nested/dynamic/effectful Composition,
held-job/shared-backend continuity, cold-start input and matched performance
remain part of the broader goal (#42799).

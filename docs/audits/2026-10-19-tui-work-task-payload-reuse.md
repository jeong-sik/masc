# Keep Work Task preparation across another Task's write

Follows #44038. Work's actual local read now captures previous immutable Task
values and reuses exactly equal values after the actual new read. Its existing
backlog cache, source admission, read/followup semantics and Keeper-metadata
independence remain in use. This unit establishes source behavior only.

## As-Is / To-Be

| Boundary | Before | Source behavior after this unit |
| --- | --- | --- |
| Whole backlog changes | Writes invalidate the backlog cache; a fresh decode replaces every Task object, including an unchanged selected Task. Physical document-input equality invalidates its ready/pending preparation. | A request captures the previous Work Task list. After I/O returns, shared CPU comparison reuses only equal Task payloads under the same exact ID. The selected Task can keep its pending/ready preparation when another Task changes. |
| Task content | ID/status alone cannot conserve the whole displayed Task. | Complete generated typed Task equality from #44038 includes body, status payloads, contract, handoff, lineage, execution links and exact Skill references. Physically equal immutable Tasks skip that comparison. |
| New observation | Row membership/order and Goal/errors/recovery come from a new local reading. | The new reading owns all these facts. Only equal Task objects are reused. New/changed Tasks remain new; removed Tasks are not copied back. An ambiguous previous ID supplies no reusable payload. |
| Resource composition | Local work runs through its own I/O job and cache mutex, separate from required Keeper metadata. | The generic source job runs preparation after the I/O submission has returned. The local-work cache lock is released before CPU comparison. Keeper metadata uses an identity preparation and waits for none of this work. |
| Ownership | Original workspace/base/source/request and cancellation owner govern completion and followup demand. | Those same owners span I/O, CPU preparation and delivery. CPU failure stays a source failure; late/retired/wrong-source results cannot apply or settle a successor. Payload reuse grants no read/effect authority. |

The pure request-local immutable index does not retain a global cache or a
second mtime/size rule. Cold reads and literally identical list pointers skip
CPU submission. Once payload reuse creates a list distinct from the raw backlog
cache list, later cache hits can still submit comparison. Index construction and
lookup cost O(n log n); exact comparisons can examine full Task content. Network,
filesystem, backlog parsing, derived projections and diagnostic costs remain.
Nothing here proves lower total CPU, Loading, input response, paint or useful
Task progress. Those costs must stay in matched actual Before/After cohorts.

## Authored resource scenario

The existing real first-loss Composition/resource scenario enters actual Work
reading with the original source Task. It reads and applies a real local
observation before preparing the document, then changes a different Task through
the authoritative backlog writer. The next actual read/CPU preparation/admission/
application keeps the original pending document completion admissible while
applying the other Task's new facts. It then changes the selected original Task
itself under the same identity, observes the new content and follows the new
preparation owner through the existing workspace-suspension/late-reply scenario.

This uses actual producers, requests, stored state and preparation decisions.
It adds no display, wording, row-order, snapshot, PTY, helper-mirror or
invocation-count tests. The scenario is authored and **unexecuted**.

## Evidence limits

Validation is OCaml parsing and whitespace/source inspection only. No local
build/typecheck/tests, CI dispatch/watch, native/model/PTY/controller/coordinator/
report run, install/restart, runtime prompt/config write or own merge. This
source result is not proof of generated-code typing, scenario execution,
installed runtime, visible UI or measured improvement.

All six original axes remain active: original Ask to original Task/useful work;
preparation attribution/frozen discovery reuse; ordinary/nested/dynamic/effectful
Composition; held/shared-backend continuity; cold-start/readability/visibility;
and matched actual cohorts retaining failed/cancelled/interrupted/unfinished
attempts. Source publication and a source approval do not complete those axes.

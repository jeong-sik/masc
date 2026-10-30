# Runtime catalogue: reuse the validated observation

Source baseline: `bb3c1045afed044ebadd8402c0b5c8e01e107efa` (#43706).

## As-Is / To-Be / Before and After

| Catalogue preparation boundary | Baseline | This layer |
| --- | --- | --- |
| Snapshot interpretations for a valid catalogue response | Two | One |
| Logical catalogue HTTP requests | One | One |
| Key-handler HTTP waits | Zero; already asynchronous | Zero |
| Full decoder output | Runtime/lanes/assignments tuple discards the snapshot | Typed product retains the validated snapshot and checked assignments |
| Configured default route | Loader decodes the whole snapshot again | Projected from the same snapshot as rows/lanes |
| Pure catalogue interpretation | Runs directly on the caller's fibre/domain | Uses existing shared response-decode CPU path with its existing inline policies |
| Interpretation observation | No catalogue-specific decode scope | `runtime.catalog.decode_wait` includes pool admission and return scheduling |

Counts are source-derived, not measured latency. The two-to-one claim applies
when the original full decoder succeeds: failed inputs already short-circuit
before the second snapshot interpretation. JSON body parsing, server computation,
network calls and other consumers' reads are not removed by this layer.

## Cause and implementation

`decode_runtime_resolved_full` already decoded and validated a complete
`runtime_resolved_snapshot`, including runtime options, lanes, default-route
consistency and an independent usage result. It then validated assignments against
those lanes and returned only runtime rows, lanes and assignments. The catalogue
loader immediately decoded the same JSON snapshot again to obtain its default route.

The full decoder now returns `runtime_resolved_catalog`: the same immutable
snapshot plus its checked assignments. The catalogue loader projects rows, lanes,
assignments and default route from that product inside the existing response-decode
CPU boundary. HTTP, authentication, ETag cache handling, request ownership and UI
admission remain with their existing callers. No compatibility reader, fallback
parser, new pool, model/provider rule or arbitrary limit is added.

The narrower `decode_runtime_resolved` projection and the Overview runtime-row
projection consume the new product directly. Overview retains independent catalogue
and usage errors and its existing separate usage-window decoder; this layer does
not claim to deduplicate every usage interpretation or share every resolved reader.
The standalone Runtime surface continues to use its snapshot reader.

## Preserved protocol and ownership

Assignments still reject references to lanes absent from this very snapshot.
Duplicate runtime IDs, wrong endpoint source, default/runtime inconsistency and
malformed fields retain their existing validation. Runtime, lane and assignment
order remains server order. Configured default route remains distinct from its
resolved entry runtime. An unavailable assignment keeps its typed reason instead
of being reclassified from catalogue membership.

A missing usage-window observation stays an inner error in an otherwise valid
snapshot. It is not replaced with empty windows or used to reject healthy catalogue
rows. Pure worker interpretation neither publishes data nor changes workspace/read
authority. Existing shared catalogue ordering, withdrawal, queued fresh demand,
retained observations and UI visibility from #43706 remain the caller's decisions.

## Evidence and remaining observation

Five changed OCaml files passed parsing-only checks, with diff hygiene recorded
separately. Two new feature/protocol scenarios are authored, unexecuted: route,
runtime, source and assignment provenance with an independent usage error; and
rejection of wrong-source, absent-lane and duplicate-runtime documents. Existing
full-catalogue, lane-origin and typed unavailable-assignment consumers are adapted
to the new product. No wording/layout/row-order/snapshot-output/PTY tests are added.

The source interface change is traced through ML/MLI, catalogue and Overview
loaders, the narrow decoder projection and direct protocol/assignment consumers.
Parsing and source tracing do not establish typing, test execution, independent
review, merge, installed behavior or painted frames. No local Dune/typecheck/tests,
CI dispatch/watch, native/model run, install/restart or live config write is part
of this unit.

Future matched comparison must pin source and installed binary, hold the same
workspace/response/consumer overlap, and separate server time, body parse,
snapshot interpretation, pool/return waiting, UI admission, actual paint and first
usable input. Keep failed, cancelled, interrupted and unfinished samples rather
than deriving improvement only from successful reads. No measured speedup is
claimed here. Preparation/discovery attribution, cold-start input, Ask-to-original
Task/useful work, resource-owned Composition and held-job/shared backend reuse
remain in the full objective.

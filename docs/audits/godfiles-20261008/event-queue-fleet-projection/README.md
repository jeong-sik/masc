# Event queue fleet projection, 2026-10-09

Parent: `806af2dc0d541ce4bf8b5dc21ecba1fd8526215f` (#42021).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Keeper_event_queue_persistence` mixed locked durable storage with fleet count
aggregation, source-age calculation and diagnostic JSON projection. The pure
part now belongs to `Keeper_event_queue_fleet_projection`, which receives
captured owner facts and queue observations. Its per-Keeper summary is opaque.
Storage discovery, lifecycle callbacks, state acquisition, read-error diagnosis
and canonical path resolution remain at the persistence boundary in their
original order. Existing API constructors are manifest re-exports of canonical
types; the residence JSON function is a direct binding.

The projection retains the existing wire fields, order, six owner lifecycle
classes and detailed read errors. Unknown owner lifecycle does not imply an
incomplete queue read. Source age remains separate from queue residence, whose
first admission time is not stored and therefore remains unknown. Health policy
continues to decide whether an operator should act. The projection does not
read files, query owners, call the clock or supply an operational verdict.

Persistence changes from 2,107 to 1,791 lines. The new pure owner has 350 lines.
[extraction-comparison.json](extraction-comparison.json) records ten byte-identical
pure helper bodies. Falling below the campaign threshold does not complete this
candidate's storage, WAL, discovery, quarantine, cache and transition audit.

## Consumer checks

| Boundary | Executed evidence | Result |
| --- | --- | --- |
| Persistence acquisition → pure fleet projection | New real-store scenario with all six lifecycle classes, unknown-owner cause, source age, corrupt one queue, retained five valid counts and preserved rejected bytes | 1 Alcotest case passed |
| Fleet read → canonical owner lock | Existing plain runner: cross-context isolation, waiter cancellation, exception release and fleet summary blocking until a concurrent owner commit | All 4 scenarios returned; final OK |
| Queue JSON → health actionability | Existing fixture-based health consumer: unavailable, operator standing decisions, lifecycle classes and read-error reasons | 13 Alcotest cases passed |

All three executables built successfully. [checks.json](checks.json) records exact
commands, terminal results and executable hashes. [source-sha256.json](source-sha256.json)
records changed inputs and the direct consumer/purity context. The health fixtures
verify its policy separately; they are not a deployed end-to-end health check.
The old root `test/test_keeper_event_queue.ml` fleet snippets were consulted but
are not a registered current target and were not executed.

## Scope

Evidence is limited to focused macOS compilation and isolated queue/concurrency
and health fixtures. Provider execution, live Keeper continuity, visible UI,
installation, deployment, full CI and whole-stack approval remain unverified.
This is a bounded partial repair in the original 171-candidate inventory.

# Overview Runtime catalogue and usage: one interpretation, independent results

Source baseline: `c342137c534e9c103803561dd6a9b10f61b046b3` (#43707).

## As-Is / To-Be / Before and After

| Overview preparation boundary | Baseline | This layer |
| --- | --- | --- |
| Usage-window interpretations when catalogue validation reaches the usage step | Two: inside snapshot, then independent usage decode | One captured usage result reused by both products |
| Usage interpretations when catalogue validation fails before that step | One independent usage decode | One |
| Snapshot interpretations | One | One |
| Logical runtime/resolved GETs | One | One |
| Key-handler HTTP waits | Zero; already asynchronous | Zero |
| Availability | Catalogue and usage are independent results | Same independent results in a typed observation product |
| Quota scope provenance | Snapshot resolves identity using its own usage decode | Snapshot uses the exact usage result carried by the observation |

These are source-derived counts, not timed improvement. The reduction applies
after the catalogue reaches the original usage interpretation point, including
failures later in runtime/lane/assignment validation. Early header/source failures
already caused only one independent usage interpretation. Transport failures do
not enter the decoder. Other readers and authentication calls are outside this
one Overview read; no extra HTTP request is added.

## Composition and independent failure

`runtime_resolved_observation` carries `rro_catalog` and `rro_usage` as separate
results. The decoder captures usage once from the immutable response, then supplies
that result to snapshot validation and assignment validation. When catalogue is
valid, its snapshot's usage is the same captured result. If catalogue fails early
or late, its error does not erase an independently readable usage observation.
Malformed usage remains an error, while otherwise valid runtime rows continue
with unknown quota identity. Both failures stay failures; neither becomes empty
success or an observation borrowed from another response.

The existing snapshot parser is factored around a private pure usage reader, and
assignment validation around a private builder using that validated snapshot.
Those builders own the original validation bodies, not parallel copies. Snapshot-
and full-catalogue-only entrypoints keep their original validation order: an early
source/header refusal does not trigger otherwise unneeded usage interpretation.
The observation entrypoint deliberately captures independent usage even when its
catalogue will be refused, matching the prior Overview partial-failure contract.
The private interfaces cannot be used externally to mix snapshots and responses.

The Overview loader projects its existing result tuple from the new product in
the same `runtime.quota.decode_wait` CPU scope. Network failure still fails both
results with its original reason. HTTP/cache handling, shared CPU policies,
cancellation, source ownership, dataset admission and rendering are unchanged.
This does not merge Overview's reader with the catalogue or Runtime surface reader.
No new pool, fallback parser, model/provider rule, timeout or action cap is added.

## Source and quota identity continuity

Strict source/default/runtime/assignment validation is retained. An assignment
that names an absent lane cannot publish a catalogue merely because usage is valid.
The usage state and window discriminators retain the existing closed parser;
unrecognised or malformed values are errors. Response-local quota ordinals remain
paired with the stable quota identity from that same response. A later response
that reuses an ordinal cannot rewrite an older immutable observation.

Two feature/protocol scenarios are authored, unexecuted: valid/failed/replaced
usage observations keep their own quota identity and healthy catalogue; and early
source, malformed-runtime and absent-assignment-lane failures retain independent
usage, including the both-failed case. The existing quota-provenance scenario
continues to exercise the snapshot-only reader using shared protocol fixtures.
No wording, layout, screen row-order, snapshot-output or PTY tests are added.

## Evidence and next observation

Four changed OCaml files passed parsing-only checks; diff hygiene is recorded
separately. The ML/MLI product is traced through the Overview loader and its
existing runtime-quota dataset caller. Other public snapshot/full/narrow decoder
contracts are unchanged. The Skill description and guidance cover this shared
interpretation and partial-result contract.

No local Dune/typecheck/tests, CI dispatch/watch, native/model run, install/restart
or live config write is part of this unit. Parsing and source tracing do not prove
typing, scenario execution, independent review, merge, runtime continuity, a
painted frame or faster first usable input.

Matched future observation must pin source and installed binary, reuse the same
response and workspace conditions, and include healthy, early/late catalogue
failure, usage failure and both-failed samples. Preserve cancelled, interrupted
and unfinished samples. Distinguish server/transport/body parse, usage/snapshot
interpretation, pool/return waiting, UI admission, actual paint and useful Keeper
work. No measured speedup is claimed. Preparation/discovery attribution, cold-start
input, Ask-to-original-Task/useful work, resource-owned Composition and held-job/
shared backend reuse remain in the full objective.

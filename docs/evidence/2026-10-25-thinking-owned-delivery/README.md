# Owned thinking replacement through redaction and journal replay

Relates #27924 and #45962. Parent #45950 at `3bb76a77e056db40414dda4c5c297c111e2ca35a` separately records284 component cases. That success did not establish this joined boundary.

## Reproduced failures

The new scenario uses actual `Keeper_autonomous_stream.create/on_event/finish`: its scoped secret redactor, stream bridge and publication hook write the real durable turn journal. The ordinary journal reader feeds `Masc_tui_keeper_chat_log.add_journaled` and `Transcript.apply`. A known fake token is captured through the existing remote-token redaction file, without a provider or network token request. Summary block0, sibling block1 and answer block2 are published before full reasoning replaces block0. Its fake secret spans the replacement and next delta.

The initial run [40196487790](https://github.com/jeong-sik/masc/actions/runs/40196487790), exact `f2393a6e9d15be622d0ef1a82bcc51cfd89bbc6a`, failed before execution: Unbound module Unix. The test stanza now explicitly names unix, eio_main, masc.fs_compat and masc.masc_types for its direct imports. This is a fixture correction, not a product failure.

The dependency-corrected baseline [40196629463](https://github.com/jeong-sik/masc/actions/runs/40196629463), exact `0c2507b8506f9cd929773d6b47a06675e72f987b`, compiled and ran108 cases: **one failure and107 passes**. Actual journal publication, initial owned reasoning, exact-secret absence and owned clear snapshot assertions passed. The replaced reasoning was wrong: expected `replacement [REDACTED] complete\nsibling\n`, received `sibling\nreplacement [REDACTED] complete\n`. Later answer, cold reconstruction and dedup assertions in this case were not reached.

Dashboard's separate regression also failed: **138 passes /1 failure,139 cases**. After a clear snapshot and safe replacement prefix, reconstructing the in-memory batcher before the next delta lost the prefix; the stored owned block contained only ` complete`. This is actual local Vitest failure, not a source prediction. Its committed test is at9b5d426fd94 (full source identity is retained in Git history).

## Repair

TUI thinking deltas with an explicit response generation/scope and block index append to that owned block's existing buffer. Updating an earlier block rebuilds aggregate thinking in stored block order. Anonymous observations retain chronological stretches. A closed private append-position outcome preserves append-only work for contiguous fragments; it does not rescan/copy all prior text on each ordinary contiguous delta.

Dashboard reconstructs a pending delta's prefix from the same exact owned block even when a sibling is the final trace step. Anonymous/indexless lookups retain their existing last-stretch rule. No event type, persisted codec, server control, capability or model catalog changes.

The same Dashboard command then passed **139 cases**. Source hashes bind all five production/fixture files at `abb125d4e13994e74d5490c71cf26407be61b82a`. Corrected TUI [40196874006](https://github.com/jeong-sik/masc/actions/runs/40196874006) targets that exact head; result pending inspection. Earlier corrected40196789259 targeted05dab5e1cd5 before the contiguous-append optimization and cannot certify its final performance behavior.

## Scope limits

The joined scenario's cold reconstruction is a fresh log/transcript reading the same real journal in the same process. It is not an OS process restart, actual model request, provider SSE parse, rendered TUI/Dashboard, installed runtime, MiniMax native binding/HTTP, full regression or issue completion. The Dashboard test covers state batching; it is not an actual journal→browser execution.

No local Dune build or typecheck was run. Changed OCaml parses and full whitespace/fragment checks are separate syntax/source checks. The issue stays OPEN. Native Stack submit again reports disabled; REST stack is null and this layer keeps #45950's branch as its exact base.

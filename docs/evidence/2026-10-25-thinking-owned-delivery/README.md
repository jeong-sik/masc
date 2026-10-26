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

The same Dashboard command then passed **139 cases**. Independent review of that correction found another P2 by source: rebuilding only the newest response's buffers lost earlier responses in the same attempt. This was not an executed failure in the108-case baseline; its new controls did not exist there. The helper now rebuilds all reasoning in the current attempt/continuation segment, stopping at superseded or segment boundaries. New controls preserve a previous response through interleaved append and snapshot replacement, then exclude it after supersession. The earlier independent PASS missed this and is superseded.

Source hashes bind all five production/fixture files at `c0f2f3032b0cb998bb66b74b29433c242d63df34`. Corrected TUI [40197182110](https://github.com/jeong-sik/masc/actions/runs/40197182110) was dispatched for that exact head; the final observed outcome is recorded below. Earlier40196789259 at05d preceded the contiguous-append optimization, and40196874006 atabb preceded earlier-response preservation. Neither certifies the final source.

## Scope limits

The joined scenario's cold reconstruction is a fresh log/transcript reading the same real journal in the same process. It is not an OS process restart, actual model request, provider SSE parse, rendered TUI/Dashboard, installed runtime, MiniMax native binding/HTTP, full regression or issue completion. The Dashboard test covers state batching; it is not an actual journal→browser execution.

No local Dune build or typecheck was run. Changed OCaml parses and full whitespace/fragment checks are separate syntax/source checks. The issue stays OPEN. Native Stack submit again reports disabled; REST stack is null and this layer keeps #45950's branch as its exact base.

## Observed intermediate joined execution

[40196874006](https://github.com/jeong-sik/masc/actions/runs/40196874006) checked out exactly `abb125d4e13994e74d5490c71cf26407be61b82a` and completed SUCCESS: **109 actual cases**. The joined production collector→redactor/bridge→durable journal→TUI replay assertions passed, including retained replacement position, unaffected answer, readable projection, fresh same-process journal reader and sequence deduplication. The owned/anonymous append control passed too.

This is intermediate source before the independently found earlier-response aggregate correction. It does not certify that later correction or its added control. The final110-case request40197182110 is distinct; its observed outcome is recorded below. The actual109 success is retained even though the earlier-response concern remained outside that fixture's coverage. Neither this109 nor Dashboard139 is a rendered UI or OS restart result.

## Observed final corrected execution

[40197182110](https://github.com/jeong-sik/masc/actions/runs/40197182110) checked out exactly `c0f2f3032b0cb998bb66b74b29433c242d63df34` and completed SUCCESS: **110 actual cases**. Earlier-response preservation through append and snapshot, exclusion of superseded-attempt totals, the joined production redactor/real journal/TUI replay, unaffected answer, fresh same-process reader and deduplication assertions all passed. The raw digest, actual checkout, key assertions and suite result are retained together.

All five recorded source/fixture hashes match this source and later evidence-only heads. The earlier109 result remains historical and is not added to110. Dashboard139 is a separate state test result. No full regression, whole executable/release build, OS restart, rendered screen, provider parsing/HTTP, native activation, installed runtime, deployment or whole-issue closure is claimed.

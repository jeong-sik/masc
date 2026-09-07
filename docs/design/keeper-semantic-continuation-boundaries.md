# Shared conversation and semantic continuation

A Keeper can retain A while completing B. Continuing A must preserve what the
Keeper learned during B. The shared conversation and one invocation's execution
identity have different authorities.

| State | Authority |
| --- | --- |
| Latest shared messages, turn count and usage | Current Keeper canonical checkpoint |
| Original A input, source membership and repetition frame | A's durable semantic admission |
| A's accepted checkpoint bytes | Exact retained artifact and reference |
| Completed cooperative tool boundary | SDK-produced turn and checkpoint stage |
| Interrupted external effects | Exact provider/session and effect receipts |

`Runtime_agent.run_result.cooperative_boundary` now carries the SDK's returned
`Advanced.Yielded` turn and stage through Keeper finalization. Normal completion,
input-required errors and official clients do not synthesize this SDK witness.
A Gate-deferred call can still let the same turn continue normally.

The SDK calls the cooperative probe after tool execution, optional context
injection and the configured checkpoint sink have succeeded. A sink may be absent,
so crossing the boundary alone does not establish durable storage. Keeper's final
save may also produce a stale no-op: the boundary remains evidence of the SDK
return even when no new checkpoint is published. A journal suspension therefore
needs both the producer boundary and independent exact checkpoint retention.

## Shared history is not rolled back

`Agent_checkpoint.build_resume` restores the checkpoint's messages, turn count and
usage verbatim. `Advanced.continue` continues that state without adding a new
input; it does not resume an OCaml fiber. Loading A at turn 1 after B saved turn 21
would discard B from the provider conversation and trigger the canonical stale
save guard on A's next turn. The retained-A artifact is not permission to do this.

A cooperative continuation must retain the latest shared conversation while
selecting A's original admitted input, explicit continuation descriptor and exact
repetition scope. Neither the last User message nor a transcript suffix supplies
that original input. Source hashes do not recover a payload once its queue rows
have been acknowledged. Persist the input at admission before native wiring.

Interrupted in-flight execution has a different contract. SDK execution resume
validates exact tool-use/tool-result identity and checkpoint topology. It cannot
substitute B's transcript or treat an empty repetition frame as proof of no
external effect. This needs an adapter-owned recovery decision joined to the
specific session/attempt and effect receipts.

## Verification scope

Three new local-provider scenarios exercise HTTP response, actual tool execution,
optional checkpoint sink and cooperative yield. They require one provider call
and one tool call, preserve the observed turn/stage, and reject a failed sink
before the cooperative callback. The existing Gate-deferred completion scenario
also checks that no yield witness is fabricated. These are remote-CI cases; no
local build or test execution is claimed.

This change preserves evidence. Scheduler selection, semantic input admission,
parent/child bindings, journal publication, cleanup ownership and interruption
reconciliation remain separate integration work. It adds no admission limit or
new automatic resume decision.

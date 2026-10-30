# HITL decision, wake and grant model

`specs/keeper-state-machine/KeeperHitlDeferred.tla` models one approved external
effect request for an existing Keeper. Its boundaries are the committed pending
request, committed decision, durable wake acceptance, process-local signal and
one-shot grant consumption. These boundaries are separate in production: a
decision survives failure to enqueue or signal its wake.

## State interpretation

| Model value | Production meaning |
| --- | --- |
| `request_phase = absent` | No pending request or resolution delivery for this logical request. |
| `pending` | The pending journal owns the accepted request. |
| `resolved` | The decision is journaled in `deliveries`; its matching grant remains unconsumed. This does not assert successful wake delivery. |
| `consumed` | Matching approval grant consumption is committed. It does not assert that the external effect succeeded. |
| `wake_durable` | The addressed `Hitl_resolved` stimulus has been accepted by the durable event-queue boundary. It is a monotonic witness in this bounded model, not a claim that the row remains queued forever. |
| `wake_target` | A process-local scheduling signal, cleared on model restart or consumption. It is neither the decision store nor the event-queue row. |
| `consume_count` | Successful logical grant consumptions, rather than model invocations, wake attempts or tool effects. |
| `submitter_blocked` | Waiting for the operator's decision. Ordinary journal I/O and scheduling can still suspend. |

The committed store is the abstract state. A rejected write before commit is a
stuttering step. Restart preserves committed state and loses only the transient
signal. `MaxProgress` bounds the finite model's progress observations; it is not
a runtime budget, timeout or admission limit.

## Production correspondence

The source was read at `c5337092c70bc5cf6a615f481684810db40a7116`. Function names
below identify the inspected boundaries; they are not generated source-parity
assertions. A later change to one of these boundaries needs a new correspondence
review, even when the model still passes.

| Model action | Actual boundary and ordering |
| --- | --- |
| `SubmitDeferred` | [`Keeper_approval_queue.submit_pending`](../../lib/keeper/keeper_approval_queue.ml) calls `persist_snapshot_with_sequence_unlocked` before publishing the new pending map or returning a created receipt. [`Keeper_gate.defer`](../../lib/keeper/keeper_gate.ml) turns successful submission into `Deferred`; it does not wait for a human resolution. Deduplicated requests and existing grants are separate production outcomes, outside this one-new-request model. |
| `ResolveForOrigin` | `Keeper_approval_queue.journal_resolution` removes the pending entry and adds the decision delivery only after the store operation succeeds. `resolve_with_policy` records the journaled decision before calling `complete_delivery`. No wake has been implied by this action. |
| `CommitWakeForOrigin` | `complete_delivery` calls `deliver_resolution` with `delivery.entry.keeper_name`. [`Keeper_registry_event_queue.enqueue_hitl_resolution_durable_result`](../../lib/keeper/keeper_registry_event_queue.ml) checks recipient existence and the shutdown intake fence, then uses `enqueue_durable_result_unfenced`. That owner publishes the pending event only after `Keeper_event_queue_persistence.update_checked_result` succeeds. An enqueue error leaves the journaled delivery available for replay. |
| `SignalOrigin` | Only after durable enqueue and the requested standing-rule step succeed does `complete_delivery` call `signal_resolution_after_commit`. It passes the original entry's Keeper and base path to `Keeper_registry.wakeup_running`. An offline lane or signal exception does not undo the decision or its accepted wake. |
| `Restart` | Queue installation restores the journaled deliveries and spent-grant flags. `complete_delivery` can replay an unspent delivery; it skips another wake for an already consumed grant. Losing a process-local signal therefore does not erase the decision. Installation, schema rejection, corrupt stores and physical crash durability are outside this model's successful-store assumption. |
| `ConsumeOnce` | `consume_approved_resolution` checks the stored workspace, approved decision, original Keeper, exact tool and input fingerprint. It persists `grant_consumed = true` before publishing that state. A subsequent call returns `Consumption_already_committed`, not another permission. A direct operation can observe the journaled decision before a wake, so model consumption intentionally does not require `wake_durable`. |

`ProgressOrigin` and `ProgressOther` abstract independent work. Weak fairness for
`ProgressOther` and `ConsumeOnce` is an explicit liveness assumption, not evidence
that a missing, stopped or failing consumer will run. The model does not promise
fair filesystem locks or isolate a stalled global store write. It also excludes
rejection presentation, recipient removal, standing-rule failures, delivery-row
retirement, response transmission, multiple approvals and external-effect crash
recovery. Those paths must keep their own production evidence.

## Verification

The existing runner, [`scripts/tla-check.sh`](../../scripts/tla-check.sh), registers
the normal configuration and five independent negative configurations. Run only
this model by invoking its registered TLC command with each corresponding cfg in
an isolated temporary directory. The runner names `tla2tools-1.8.0.jar`; this
execution used the installed jar whose actual banner is
`TLC2 Version 2026.05.26.235334 (rev: 4ba7d88)`. Its SHA-256 is recorded in the
receipt; the filename alone is not used as version evidence.

| Configuration | Expected result |
| --- | --- |
| `KeeperHitlDeferred.cfg` | Exit 0: type/safety invariants and both conditional liveness properties hold. |
| `KeeperHitlDeferred-blocking-buggy.cfg` | Exit 12: submission waits for a decision. |
| `KeeperHitlDeferred-wake-buggy.cfg` | Exit 12: a committed wake signals another lane. |
| `KeeperHitlDeferred-consume-buggy.cfg` | Exit 12: a grant is consumed twice. |
| `KeeperHitlDeferred-early-signal-buggy.cfg` | Exit 12: the origin is signaled before durable wake acceptance. |
| `KeeperHitlDeferred-restart-buggy.cfg` | Exit 13: forgetting a committed decision on restart breaks eventual consumption, even with the same consumer fairness assumption. |

The negative cases check their named invariant or property individually. A parser error,
missing configuration or unexpected exit does not count as a caught bug. The
candidate's commands, source hashes, state counts and violation traces are in
[`hitl-model-verification.json`](../evidence/oldest80-hitl-model-verification.json).
This is focused model execution and source correspondence, not a new OCaml build,
formal refinement proof, live Keeper scenario or CI result.

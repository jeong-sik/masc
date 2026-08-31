# task-1194 — connector attention settlement evidence

GitHub issue #32096.

## Claim

A completed Keeper cycle must not turn missing or mismatched continuation
evidence into an `Ignored` decision. The implementation records only facts
owned by producers and applies queue policy afterward.

| Producer evidence | Queue / ledger action |
|---|---|
| matching `Surface_post_completed` receipt | ACK + `Resolved` |
| mismatching `Surface_post_completed` receipt | pending; no ledger write |
| `Memory_write_completed` receipt | ACK + `Ignored` with the narrow existing reason `turn_completed_without_direct_reply` |
| no terminal-effect receipt | pending; no ledger write |
| no continuation route for this wake | pending; no ledger write |

`Memory_write_completed` does **not** mean “the model observed the connector
message and chose not to reply.” It proves only that a concrete non-surface
terminal effect completed. Likewise, a missing receipt does not prove that the
model failed to observe anything. The public variants keep those weaker facts
instead of naming inferred mental states.

## Source boundary

`Keeper_unified_turn.continuation_route_disposition` is an exhaustive sum:

```ocaml
type continuation_route_disposition =
  | Continuation_route_addressed
  | Continuation_route_mismatch
  | Continuation_memory_write_completed
  | Continuation_no_terminal_effect_receipt
  | Continuation_route_not_applicable
```

The constructor is chosen by an exhaustive match over the optional
continuation route and producer-owned `terminal_effect_receipt`. Adding a new
receipt kind therefore forces this boundary to be reconsidered at compile
time.

`Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome` is separately
exhaustive over the evidence sum. Only addressed surface delivery and a
completed memory terminal effect ACK the batch. Mismatch, missing receipt, and
an inapplicable route remain `Batch_no_action`.

## Regression pin

`test_keeper_connector_attention_batch` checks:

- matching surface receipt -> `Attention_resolved`;
- memory-write receipt -> `Attention_ignored`;
- mismatch, no receipt, and no route -> `Batch_no_action`;
- durable-stimulus checkpoint retains its pre-existing special disposition;
- every terminalizing disposition maps to an external-attention settlement.

`test_keeper_failed_selection_disposition` also uses the evidence-level
`Continuation_no_terminal_effect_receipt` fixture so failed and checkpointed
cycles do not reconstruct an intent label.

## Prior observation, not current-head proof

Before this correction, the sangsu external-attention ledger contained 292
events, including 103 ignored rows all carrying
`connector_attention_turn_completed_without_direct_reply`. That distribution
is the incident baseline; it does not reveal which rows were true direct-reply
absence, route mismatch, or missing receipt, because the old catch-all had
already destroyed that distinction.

An earlier branch revision (`f0334d5e73`) reported `dune build @all` and the
focused connector-attention suite green. Those results do not prove the
rebased and renamed branch tip. Current-head compilation and focused test
execution are intentionally left pending for the operator's verification.

No live post-change ledger measurement is claimed here. Such a measurement
requires deploying the exact built revision and observing new connector
attention events; historical rows cannot be reclassified after the fact.

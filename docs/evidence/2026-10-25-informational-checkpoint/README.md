# Informational completion input and checkpoint ACK — 2026-10-25

Relates #26165. Source base: d98835aec86ae8c302b4cc43474c249ef1425d29.
Test candidate: 2c29596384be4f99cc7d8edbd7da33af1593fd38.

## Current contract and observed source

The original report's completion-only ACK premise does not describe current
heartbeat code. `Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome`
selects `Batch_ack_attention_only` for every current typed checkpoint reason.
The actual loop then terminalizes admitted non-Connector selections through
`Keeper_registry_event_queue.terminalize_pending_turn_completed_result`.
HITL has an additional durable continuation-projection check; Connector input
retains its separate checkpoint behavior. Failed/cancelled/input-required/skipped
outcomes select `Batch_no_action`. No new per-payload ACK policy is introduced.

Fusion/Delegate/Composition completion still looks actionable at intake when it
is pending. That alone is not redelivery evidence: the turn-end consumer may
already have durably acknowledged it. This distinction motivates the joined
behavior test rather than a new heuristic, arbitrary limit or settlement store.

## Added behavior verification

`test/test_keeper_informational_checkpoint_ack.ml` drives the production Owner,
heartbeat intake, turn driver and native runtime against one controlled loopback
streaming provider response. Three typed completion sources are durably queued.
Their actual input markers must reach the provider request and saved canonical
checkpoint. A later person operation admitted during the provider request causes
the real turn to yield with `Operation_queued`. The actual heartbeat shell must
ACK all three admitted completion sources and retain a later Bootstrap source.
A separate executable process reopens the checkpoint, reads durable reaction ACK
facts and performs the next intake: exactly the later work, no old completion.

Provider text/tool-call response, completion inputs and the person-operation
runner are controlled fixtures. No Board post, external message or sandbox tool
executes. Docker provides the Keeper sandbox; the fixture explicitly promotes
the CI image into its private workspace catalog. The fresh process does not run
a second model turn or prove completed Bootstrap work, live vendor behavior,
all checkpoint reasons, crash cuts, all read-failure paths or fleet behavior.
Existing failure-disposition tests are selected separately for their actual
scope; their presence is not a passing execution.

## Validation state

Changed OCaml parses with `ocamlc -stop-after parsing`; committed diff whitespace
passes. Independent adversarial SOURCE PASS at the candidate; response review is
completed at that historical head. These are source checks, not type-check/build/runtime results.

[Explicit run40185754758](https://github.com/jeong-sik/masc/actions/runs/40185754758)
requests only `test/test_keeper_informational_checkpoint_ack` and
`test/test_keeper_failed_selection_disposition`. Non-minimal preparation supplies
Docker; selecting these two targets is not a full regression. That run actually FAILED before either selected test executed: the test named
nonexistent `Q.High`. The complete diagnostic was read; the failed receipt is
retained in failed-run40185754758.txt. Both prior source verdicts at2c295963
are invalidated by this compile evidence. Current correction uses the actual
`Keeper_event_queue.Normal` constructor at all three sites; it does not change
any production urgency or ACK policy. Corrected execution is requested separately. No local Dune/build/typecheck was run. #26165 remains open
until its current acceptance is actually verified.

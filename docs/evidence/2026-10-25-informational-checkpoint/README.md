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
passes. Historical source reviews did not establish fixture execution; both subsequently
failed runs below qualify those verdicts. Source review is not execution evidence.

[Explicit run40185754758](https://github.com/jeong-sik/masc/actions/runs/40185754758)
requests only `test/test_keeper_informational_checkpoint_ack` and
`test/test_keeper_failed_selection_disposition`. Non-minimal preparation supplies
Docker; selecting these two targets is not a full regression. That run actually FAILED before either selected test executed: the test named
nonexistent `Q.High`. The complete diagnostic was read; the failed receipt is
retained in failed-run40185754758.txt. Both prior source verdicts at2c295963
are invalidated by this compile evidence. Current correction uses the actual
`Keeper_event_queue.Normal` constructor at all three sites; it does not change
any production urgency or ACK policy. The corrected run40186573395 at9a79e6f6ab55db9c856ca704691e6eda5bf97fc9
compiled both selected executables. Its new scenario then FAILED before reaching
the provider: the fixture omitted the application-owned native request journal
runtime installed by server bootstrap. The existing failed-selection suite
actually passed all16 cases. The second failed receipt is retained in
failed-run40186573395.txt; this failure is not evidence of a production ACK bug.

The fixture now explicitly initializes `Runtime_agent_execution_runtime` with
its application switch and Eio domain manager, using the same public capability
as server bootstrap and existing native integration fixtures. Scope release
cleans up that capability; the fresh-process reader only reads checkpoint and
queue state and needs no native execution runtime. No production code or ACK
assertion was weakened. Run40187045370 atfc7a223d709164c55a7e5e896374a294e489609a subsequently
compiled both executables and reached actual provider/tool execution and an
Operation_queued checkpoint. The assertions for ACK disposition, stop reason,
one provider request and all three markers in that request passed before the
fixture failed reading its checkpoint: it supplied the Keeper name to
`keeper_session_dir`, whose public argument is the trace ID. The recorded
checkpoint_save rows and original failure are retained in
failed-run40187045370.txt. Existing disposition16 passed again.

The fixture reader now derives one trace ID from effective metadata and uses
it for both session directory and checkpoint ID, matching the production session
layout. It still requires checkpoint content, persisted ACKs, later-work queue
and fresh-process intake assertions; those later assertions were not reached
in the failed run. No production writer/path policy changed. Corrected execution
is pending.

No local Dune/build/typecheck was run. #26165 remains open until its current
acceptance is actually verified.

# Informational completion delivery, native journal and checkpoint ACK

Relates #26165, September30 residual: delivery evidence, no repeated selection
and later-work retention after restart. Source base:
d98835aec86ae8c302b4cc43474c249ef1425d29. No production ACK policy is changed.

## Current contract

Every current typed checkpoint selects Batch_ack_attention_only. The heartbeat
terminalizes admitted non-Connector selections using the durable source-bearing
completion path. HITL additionally requires continuation projection. Failure,
cancellation, input-required and skipped outcomes keep the batch pending.
Pending/actionable intake alone is not evidence of redelivery after ACK.

World observations intentionally ride dynamic_context and remain out of the
persisted AGENT_CORE conversation (keeper_unified_turn's build_turn_prompt).
AGENT_CORE agent_turn retains the extra context only for Anthropic signed-prefix
replay; OpenAI-compatible providers use request-only context. Checkpoint JSON
therefore need not contain verbatim Fusion/Delegate/Composition result text.
The heartbeat's contrary explanatory comments are corrected without changing
its policy. A delivery ACK does not certify model-level answer continuity.

## Joined fixture

The actual Owner/heartbeat/native turn admits three informational completions.
One controlled loopback provider returns a keeper_context_status tool call.
During its request, the fixture enqueues later Bootstrap work and an actual
person operation, causing the real Operation_queued yield.

The test requires:

- Actual received request body includes all three result texts and source IDs.
- The persisted TurnRecord's native request evidence can be reopened from its
  authoritative Core journal and agrees with its original observation. The
  sealed serialized SHA/length must match the peer's actual body.
- The canonical checkpoint reloads under the effective trace ID and retains
  the actual assistant tool call and corresponding result at turn1.
- All three exact source ACKs and canonical strict delivery evidence exist,
  without cancellation; later Bootstrap alone remains pending.
- After application-switch release, a separate executable process installs a
  read capability, reopens journal/TurnRecord, validates the same peer capture
  against the durable digest, reloads canonical checkpoint and ACK/delivery
  evidence, and admits only later work through actual intake.

The peer body file is private fixture capture, not a new production ledger or
resume authority. The Core serialization witness is digest/length evidence;
it does not reconstruct request text. Provider response and person runner are
controlled. Docker catalog/preparation is explicit; no external messages or
sandbox tools execute.

The child does not run a resumed model turn or complete Bootstrap work. This
proves only the declared delivery/ACK/fairness boundaries if it passes, not
semantic answer continuity, official-client session restart, every terminal
variant/checkpoint reason/crash cut/read failure, live vendor or fleet.

## Actual failed executions and corrections

All failed run excerpts retain their full raw-log SHA. Source verdicts at the
failed heads are historical and do not override actual failures.

- 40185754758 at2c295963: compile failure before tests, nonexistent Q.High;
  corrected to the declared Normal constructor at all three sites.
- 40186573395 at9a79e6f6: compiled both targets but failed before provider due
  to missing application-owned native request journal runtime. Fixture now
  installs the public bootstrap capability under its application switch.
- 40187045370 atfc7a223d: actual provider/tool and Operation_queued checkpoint
  reached; fixture reader used Keeper name for a trace-ID directory and failed.
  Reader now derives both directory and checkpoint ID from effective trace ID.
- 40187984732 at2d3ef156: actual checkpoint loaded, but the test incorrectly
  required raw observation text inside canonical history. The source contract
  above explicitly makes OpenAI observations request-only. This failure proves
  neither a broken serializer nor model-level answer continuity. The fixture
  now joins actual delivery to the existing durable request witness instead,
  while retaining checkpoint, exact ACK, queue and fresh-process obligations.

The existing failure-disposition suite passed16 cases in each of the last
three runs; those results do not establish the new joined scenario. Its later
queue/durable-ACK/child assertions were not reached in the failed runs.

## Current validation

Three changed OCaml source/interfaces parse; fragment and full committed
whitespace checks pass. No local Dune/build/typecheck or full regression.
Corrected joined execution is requested separately; no corrected PASS is
claimed here. #26165 remains OPEN, including the stronger resumed-model and
provider/session-specific continuity caveats above.

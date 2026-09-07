# Keeper repetition scope boundaries

Observed source: main `1f7ec8a587`. Audit item7 retained a repeated Execute count934 in the06:11–06:14Z runtime window. The current detector seeds from every matched tool call in the session history (`keeper_run_tools_setup.ml:237–301,480`), so an unrelated new request inherits old repetition evidence.

## Required behavior

Fresh B must not inherit A's counts. Explicit Resume A must retain A's counts across B, provider changes, checkpoints and restart. A repeat split2+2 across execution attempts must still reach the existing detector threshold. Current receipts must contain only their own tool observations. No prompt-string, task-name, last-user, `is_retry`, trace-ID or per-run reset heuristic supplies this contract.

## Actual producer boundaries

Direct HTTP, tool and connector submissions all become durable Chat_operation records. HTTP validates request_id; MCP msg generates kmsg IDs; delegate can derive an ID from an invocation reference. Discord, Slack and iMessage use connector event IDs. The claimed operation ID is available in `server_routes_http_keeper_stream.operation_executor`, but is dropped when the stored payload is decoded into `direct_message`. Carry an internal typed scope admission from this claimed operation through admitted tool-surface dispatch and Keeper_turn, binding it outside the provider retry loop.

Running direct operations currently settle as Interrupted_by_restart and discard input at owner recovery. They are not automatically resumed. Queued rows survive and duplicate terminal submissions return the existing receipt. A scope change must not resurrect terminal operations from a session checkpoint.

Autonomous intake retains exact pending selections until `keeper_heartbeat_loop.ml:830`, then converts them to payload-only Woken. Scope admission belongs before this projection. Neither admitted_revision nor source_snapshot_ref is stable lineage: defer changes revision and reprioritization changes the source envelope hash. A durable admission identity must be preserved through these transforms.

## Continuations that require explicit parent records

- HITL pending approval has an optional turn_id, but deduplication deliberately folds equivalent requests across turns. A later B folding into A's grant must not overwrite A's parent relation. The heartbeat can also peek HITL A behind primary B, so primary selection alone cannot identify its parent.
- Ask accepts optional turn_id but the actual producer does not pass it. Persist ask_id to parent-scope linkage when the ask is accepted.
- Delegate completion has a child operation ID and requesting Keeper, but its durable payload does not identify the parent scope.
- Composition request_context has a run ID and optional skill ref; its execution closure cannot establish parent lineage after restart.

Parent links must commit with durable child acceptance. Saving them only at the next checkpoint leaves a child-accepted/checkpoint-not-written crash interval.

## Checkpoint representation

Use a map keyed by durable scope identity and a separate active scope; switching to B must retain suspended A. Agent_core.Context.Session is an existing persisted extension boundary, as used by Keeper_tool_load_receipts. Verify normal and official-client checkpoint paths before wiring it. Do not use working_context as an assumed durable sidecar: patch_checkpoint_last_assistant currently clears it.

Fresh admission must be idempotent for an already-known identical operation; it must not reset prior observations. Resume requires an explicit persisted parent reference. Unknown/corrupt lineage is evidence to retain and diagnose, not permission to seed the entire session or invent a fresh scope.

## Prerequisite discovered during implementation

The event-queue loader treated a present unsupported snapshot as empty and allowed later writes to replace pending sources and disposition evidence. This must be corrected before changing durable admission shape. The associated repair keeps primary decode errors distinct from absence, preserves the primary and WAL, and confines registration failure to the affected owner. This is a durability prerequisite; it does not fix item7 by itself.

## Required integrated evidence

Exercise actual admission and execution: A executes twice, Fresh B executes the same tool once without yielding, then after a checkpoint/restart explicit Resume A executes once and reaches the existing threshold. Also cover provider2+2, A/B/A, duplicate direct submissions, Queued recovery, Running terminal recovery, defer/reprioritize, primary B with HITL A behind it, Ask/Delegate/Composition completion and child-accepted crash boundaries. None of these scope integration scenarios has been implemented or executed by this design note.

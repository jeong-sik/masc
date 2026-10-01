# Independent Keeper execution spaces: implementation boundary

The product goal is that source work A can continue while an independent user
question B is answered. Late A tool results, cancellation and cleanup must not
modify B or release B's slot. An interrupted externally accepted effect must be
read back before any retry. Fast Jev routing cannot establish effect truth.

## First change: observation ownership

`Keeper_turn_observation_token` identifies one process-local observation attempt.
Chat and autonomous lifecycle paths allocate a fresh token and capture it in
cleanup; the autonomous event-bus callback captures that same token. Registry
finish and tool-count updates require an exact token match. Stale cleanup also
leaves the successor's wakeup signal and completed-turn record intact.

The display `total_turns + 1` counter and durable operation ID are unsuitable:
continuation attempts can reuse them. The opaque token has no wire or persistent
representation and cannot authorize external effects or cancellation.

The regression scenario in `test_keeper_composite_live_turn_surface.ml` starts
A and B with equal display counters, injects A's late callback and cleanup, checks
B's dashboard projection, and checks normal and duplicate B cleanup.

This change protects observation lifetime and tool counts only. It does not
introduce simultaneous execution, and does not claim to fix all stuck states.
Validation so far: OCaml parsing and diff checks; runtime tests not run.

## Remaining stack order

1. Attribute remaining registry progress/FSM/model/measurement callbacks to the
   captured attempt. Do not fetch the current attempt when a delayed callback runs.
2. Partition provider history/checkpoints and official-client session stores by
   execution space, preserving existing CAS, effect and continuation contracts.
3. Scope event subscriptions and emitted events by execution identity. The current
   subscription filters only keeper name, so distinct callback ownership alone
   cannot distinguish concurrent A/B tool events.
4. Replace Owner's singleton child/slot/cancel handle with owned executions;
   completion and stop must identify their exact execution before releasing it.
5. Connect Jev's fast semantic routing to these independent spaces. Typed tool
   completions and explicit stop targets bypass semantic routing. Preserve
   continuation, effect readback, and delivery ownership through interruptions.

## Required end-to-end evidence

- A source task, B independent question, B finishes, A continues its original work.
- Late A tool result and cancellation cannot change B checkpoint or slot.
- POST accepted before interruption: recover by readback without duplicate POST.
- Native and official-client runtimes both preserve these boundaries.
- Current progress, last failure and future schedule remain separate in UI.

The single-owner scheduling boundary remains in place until the corresponding
shared-state boundaries are partitioned. Source review, Core build, test execution
and deployed behavior must be reported as separate proof stages.

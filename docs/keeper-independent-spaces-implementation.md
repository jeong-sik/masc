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

## Second change: registry callback attribution

The installed token now flows from both lifecycle roots through `run_turn`,
tool setup, hook assembly and stream/progress callbacks. Progress, core-turn
reset, FSM transitions, model selection, runtime terminal state and measurement
binding match the captured token under the registry update lock. A standalone
invocation without a token does not adopt the currently active observation.

The regression creates real Agent Core before-turn hooks for A and B, then
fires A after B starts. It also injects stale or unowned registry updates while
B has a pending measurement, verifies that B's entire entry is unchanged, and
checks that B's own hook and measurement binding still work.

This protects `current_turn_observation`, not every Keeper-scoped projection.
Pending measurement production belongs to the Keeper lifecycle and requires
space attribution before concurrent execution. Preview callback ownership is
addressed in the next slice below. Session/checkpoint and external-effect
ownership are also unchanged. Source review and parsing are not runtime proof.

## Third change: preview writer ownership

Each `run_turn` creates a private preview writer before constructing any hooks.
The writer owns response text, tool/attempt/failure state, and the streaming
redactor's held partial line. Every callback captures that writer. The displayed
Keeper preview points to the most recently installed writer; an old callback can
update only its original private state, never the successor's displayed state.

Claude/Codex adapters already emit native tool start events to the per-execution
stream callback. Duplicate name-scoped preview writes are removed from those
adapters. The writer tracks tool indexes through stream start/stop so native
completion still refreshes the corresponding tool observation. Text-only stops
do not claim tool activity. Native-action evidence and raw trace observation
remain independent.

The stream regression interleaves A's unfinished text with B's split secret,
then sends A's stop/tool/failure/retry/final-text callbacks. B's snapshot remains
unchanged and B's own final delta is redacted with its original held prefix.

This is top-level execution ownership. Provider retries within the same
`run_turn` still share the writer; per-provider stream attempt attribution is not
claimed. Display selection remains latest-created execution by Keeper name.
Measurement production, event-bus FSM emission and durable sessions remain
separate shared boundaries. In particular, the event bus emits FSM records before
its token-protected registry count callback; those are not the Registry FSM.

Validation is source review and parsing, not executed tests or deployed UI proof.
The consulted Keeper lane also reports no OCaml/Dune/Opam toolchain; it cannot
supply runtime evidence. Native GitHub stack membership was observed for #40524
and #40530 after initial PR creation; direct base alone is not merge scope.

## Remaining stack order

1. Partition lifecycle measurement production and displayed execution selection
   by space. Registry callback mutation and preview writers have owned executions.
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

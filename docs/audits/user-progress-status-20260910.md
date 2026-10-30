# User progress and diagnostic separation

User acceptance: an operator can tell whether their request is waiting, executing, trying another runtime, awaiting their action, stopped, or finished. An old failure must not be presented as the current state of another request. Debug detail remains available without occupying the primary conversation.

## Evidence and work

- TUI live progress used ACTIVE TURN and an animated glyph for every transcript phase, including Waiting and Stream_failed. Initial patch uses the typed phase for the heading and animates Working only. Parser verification passed; compiled and physical TUI checks remain pending.
- Tool detail labels distinguish preparation and result waiting. The live progress row now does the same, retaining a held approval separately while exposing other current-attempt calls. The added regression covers another pending result, its own elapsed age, completion while the question remains, then a subsequent runtime attempt. Compiled CI and physical TUI proof for this change are pending.
- RUN_ERROR becomes a persistent Message_error. A request_id is present on message rows, but recovery must be joined to the same request, not inferred from a later successful turn.
- Runtime attempt events now reach the TUI; the current attempt is shown separately from superseded tool evidence. Internal provider retries still need a distinct event before the UI can describe them.
- TUI first: dashboard work is deferred per operator instruction.

## Display contract

Normal view: current action, continuation state and any action required from the user. A spinner alone is insufficient. Waiting in a queue is not running a model. A terminal request failure is not proof that the Keeper is permanently stopped.

Transient notification: a recovered failure only after matching-request recovery evidence. Do not erase an unresolved failure on a timer. Operator cancellation is a neutral outcome, not a system fault.

Debug view: provider messages, HTTP status, attempt identities, model transitions, timestamps and correlation evidence. Preserve these in system logs irrespective of normal-view verbosity.

## Remaining acceptance

Exercise queued -> running -> completed; same-request failure -> automatic retry -> recovered; all attempts exhausted; operator cancellation; approval wait; stream disconnection with unknown outcome; old failure followed by a distinct request. Verify normal and debug views, narrow terminal rendering and dashboard accessibility. No live evidence yet establishes completion of this audit.

## Call deferral and Keeper continuity

The runtime returns `Tool_result.Deferred` for an approval-bound external effect and directs the model to continue independent work (`keeper_gate_deferred_payload.ml`, `keeper_tools_agent_core_handler_exec.ml`). Approval continuation is preserved after the turn finishes (`keeper_turn.ml`). Neither a deferred call nor a retained approval proves the Keeper is globally stopped. Conversely these paths alone do not prove that another task actually ran: that requires current tool/runtime events. The progress row must expose those events while the approval remains independently actionable.

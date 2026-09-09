# User progress and diagnostic separation

User acceptance: an operator can tell whether their request is waiting, executing, trying another runtime, awaiting their action, stopped, or finished. An old failure must not be presented as the current state of another request. Debug detail remains available without occupying the primary conversation.

## Evidence and work

- TUI live progress used ACTIVE TURN and an animated glyph for every transcript phase, including Waiting and Stream_failed. Initial patch uses the typed phase for the heading and animates Working only. Parser verification passed; compiled and physical TUI checks remain pending.
- Tool Started and Awaiting_result both render RUNNING. Receipt submission is not proof of execution; audit the producer and distinguish argument assembly, submitted work and actual execution.
- RUN_ERROR becomes a persistent Message_error. A request_id is present on message rows, but recovery must be joined to the same request, not inferred from a later successful turn.
- Live transcript does not currently expose explicit retry/fallback events. Add or identify authoritative attempt transitions before promising automatic recovery in UI.
- Dashboard audit in progress: loading indicators, error alerts, runtime/keeper state and action-required surfaces.

## Display contract

Normal view: current action, continuation state and any action required from the user. A spinner alone is insufficient. Waiting in a queue is not running a model. A terminal request failure is not proof that the Keeper is permanently stopped.

Transient notification: a recovered failure only after matching-request recovery evidence. Do not erase an unresolved failure on a timer. Operator cancellation is a neutral outcome, not a system fault.

Debug view: provider messages, HTTP status, attempt identities, model transitions, timestamps and correlation evidence. Preserve these in system logs irrespective of normal-view verbosity.

## Remaining acceptance

Exercise queued -> running -> completed; same-request failure -> automatic retry -> recovered; all attempts exhausted; operator cancellation; approval wait; stream disconnection with unknown outcome; old failure followed by a distinct request. Verify normal and debug views, narrow terminal rendering and dashboard accessibility. No live evidence yet establishes completion of this audit.

# Retry observation journal integration

The originating session-owned retry now passes through the frozen driver
attempt, AgentRun subscription, typed Keeper hook and chat worker/autonomous
event bus. The canonical event journal codec preserves both original attempt
and retry report. It does not create a tool result, model text, thinking, or
runtime fallback. The event bus remains the sole seq/time/journal publisher.

Executed the retained interpreter harness twice: once against the private
original CLI capture, once against the normalized frames. Both exited 0.
It loads the complete production Runtime_json_integer, Runtime_native_tasks
and Runtime_claude_api_retry source modules with installed Yojson. Ten retries
roundtrip through the report codec; the original attempt roundtrips through
its shared codec. Negative attempt index and unsafe JSON integer are rejected.
Numeric bounds are JSON transport constraints, not runtime retry budgets.
Source/harness hashes are recorded in receipt.json.

The Keeper event-log roundtrip suite includes the new event, but that suite
was not executed. Syntax parsing is not integration typechecking or a build.
Actual chat-worker publication, durable append acknowledgement and autonomous
transport remain source-only observations. The Web/TUI wire/log projection
currently omits this event explicitly; connecting visible retry progress is
still required. Existing connector adapters neither reset speech nor render
retry metadata as an assistant message. No UI, merge or formal approval proof.

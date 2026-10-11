# Late acceptance cannot reopen a terminal response

Base: b402edafabf52da0e168e548963cefb638072dd0.

A real chat projection fixture sends text, RUN_FINISHED, then a late KEEPER_CHAT_OPERATION_ACCEPTED frame. The parent changed delivery to queued despite responseState.phase already being terminal. RED: /tmp/chat-late-acceptance-red-20261012.log.

Acceptance projection now checks the existing typed response state before changing delivery. A terminal response ignores the late acceptance frame. Authored text, response phase and delivery/stream state remain unchanged. Existing initial queued acceptance still works. No prose heuristics or additional lifecycle mirror was introduced.

The focused keeper-stream suite passed 98 tests. The command also named src/lib/keeper-response-state.test.ts, which is absent and was not executed; only one suite is claimed. TypeScript noEmit exited 0. Log: /tmp/chat-late-acceptance-focused-20261012.log. This is functional projection evidence, not a browser screenshot, actual provider/runtime, CI, formal approval or installation. Mid-stream acceptance ordering and foreign operation binding remain to be checked separately.

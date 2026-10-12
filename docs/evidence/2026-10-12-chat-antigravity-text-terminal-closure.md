# Antigravity streamed text terminal closure

Base: `12a3105160b7abb3320e236413392c006026788c`.

When an Active response step has already streamed the complete final response,
finish_response emits nothing. Previously the projection then emitted
MessageStop without closing that text block, since text closure happened only
for an explicit Text_completed or a missing final-response suffix.

Turn_finished now closes the recorded text indexes and unfinished native indexes
through the existing idempotent stop_content. The final response reconciliation
remains unchanged. Closed steps do not emit duplicate stops.

The CLI protocol fixture streams the final response as an Active agent_response
step without an explicit Done. Assertions require a streamed text block and one
stop for each distinct streamed text index. These are SSE lifecycle assertions,
not TUI display/order/snapshot tests.

Validation: adapter and fixture each passed `ocamlc -stop-after parsing`;
`git diff --check` passed. The fixture has not been executed. No build, CI,
installed runtime, browser or screenshot evidence is claimed.

Remaining: completion observer cancellation/failure and MCP asynchronous ownership
at terminal boundaries require separate verification. Overall chat goal remains
incomplete; this source correction is limited to terminal text closure.

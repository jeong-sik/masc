# Exact owned input clock authority

`chat_log_timeline_context` selects its input rows through the typed execution index and batch member keys. It then re-filtered those already-owned inputs by display request IDs and checked only the root display ID to decide whether any input was committed. An input member with an unavailable clock and no root input was treated as uncommitted; an owned input with a different display alias lost its known input time.

Project clocks directly from the already-owned inputs and test whether that collection is empty. Preserve the current no-committed-input start-time behavior and existing fallback scan excluding own output. No new identity heuristic, artificial timestamp or row ordering rule was introduced.

Interpreted actual complete typed key, message clock/floor functions, timeline index constructor, insertion helper and chat_log_timeline_context from parent/current production source. Only external source/row/role/phase types are minimal substitutes; no computation was stubbed. Parent failed `source-owned input lost its clock authority`. Current passed unknown member input with another-source visible frontier, known owned display alias, ordinary owned input and no committed input control. Artifacts `/tmp/masc-owned-input-clock-frontier-20261012/{parent,current}.{ml,log}`.

This proves selected functional clock/index behavior, not full renderer, row order, persisted producer schema, reducer or actual TUI behavior. No renderer/row-order/snapshot test was added. Source syntax-only parsing and git diff --check passed. Full fixtures/typecheck/build/CI/provider/runtime/installation/screenshots/formal approval/merge remain unverified.

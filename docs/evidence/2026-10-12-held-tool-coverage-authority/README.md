# Held tool coverage fixture correction

Original #42594 heada6b03ec509d11f8cf360857435aaeb5269f11b49 remains SOURCE HOLD.
Its inherited journal fixture used a terminal log with no tool events and a
loaded unidentified Message_tool row, yet expected all tool facts hidden.
The production change correctly retains that unmatched durable observation.

Replace stale row-text/order oracle with typed role/coverage decisions:
unidentified tool fact remains, observed speech/reasoning remain owned by the
held source. No new wording/layout/order assertions. The existing exact receipt
enrichment fixture remains unchanged. Production code unchanged in this child.

Fixture syntax-only parse and diff check pass; registered fixture unexecuted.
Original source HOLD preserved. Previous selected-function probe covers terminal
missing/observed tool decisions with explicit doubles, not complete UI pipeline.
Composite independent rereview required. No full typecheck/build/CI/runtime/UI,
installation/formal approval/merge proof. Full user objective remains active.

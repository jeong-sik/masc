# Timeline context retains typed source ownership

Base: `665b7726914ad4556e53904404a86a0e1804b5b0` (#42515).

Message rows already retain `me_execution_source`, but timeline lookup tables discarded it and indexed only raw request IDs. A direct operation failure with the same textual ID as an autonomous turn could set that autonomous block's committed-error context. The same index supplied input bounds and excluded-output clocks.

Both committed and visible lookup tables now use the existing `chat_turn_key`. Context receives a typed execution source and derives its canonical ID. Direct batches select typed Operation member keys; autonomous work selects its exact typed source. Unobserved rows cannot acquire log ownership. Both renderer consumers and the existing state/decision generator consumer were updated. No new layout/row-order test was added; new registered fixture checks failure ownership only.

Executed unchanged extracted production index/context functions under a minimal typed interpreter harness. The surrounding clock projection is simplified, and checked owned rows are output-only. Parent exited1 because the direct failure acquired autonomous context ownership; revised exited0 for cross-kind failure isolation, retained direct failure and refusal of unobserved failure ownership. Harness/logs: `/tmp/masc-tui-timeline-source-owner-20261012/`. This is isolated ownership-decision execution, not whole TUI integration, full clock projection or visible placement proof.

Syntax-only parsing passed for three changed OCaml files; diff whitespace passed. Full state fixtures are unexecuted. No full typecheck/build/CI, runtime/screenshots/formal approval/merge.

Remaining: renderer block membership and turn rails still carry raw string keys; downstream isolation requires a further bounded repair. Full provider, broadcast, queue/interleaving/async and visible verification remains incomplete.

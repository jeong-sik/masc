# TUI held-tool answer ownership and retirement

Base: 1356ab5242c8bc247040fd1647514c196c7bab92.

Source counterexamples in Surface_tool_approval_answered: it discarded finish_action's ownership flag, removed every matching provider call ID across all Keepers, and removed pending waits even for Error receipts. An old action completion could therefore mutate a newer action's approval UI; an unavailable reply could hide the still-held wait; another Keeper's same-ID wait was removed.

The handler now admits all result effects only when Approval.Flow.finish_action confirms its generation. A pure authority reducer retires the exact (keeper, call ID) tuple only for a confirmed decoded server receipt. Unconfirmed responses retain the list. Transport result classification stays at the HTTP/event shell; the core uses a closed receipt variant and gains no HTTP-library dependency. Current confirmed receipts include settled=false, because the server reports that no wait is listening.

Functional request/state tests added for unconfirmed preservation and cross-Keeper retirement. Source and Dune module boundaries inspected; git diff --check passed. Tests/build were not executed under constitution no-local-Dune execution_protocol. No runtime, TUI screenshot, CI or formal approval claim.

Remaining: (keeper, call ID) is still not a wait incarnation, so a newer same-Keeper same-ID request must eventually use a distinct server approval ID. Server/frontier propagation and the full cross-provider objective remain incomplete.

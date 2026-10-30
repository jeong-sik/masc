# Original Addon host request observations

G03 follow-up for #44824. Source and its six implementation/test blob identities
are in receipt.json. The server already emits this diagnostic via
`Lane_addon_runtime.host_status_json`/`snapshot`; the Dashboard instance schema
previously discarded it. TUI already decodes and displays it.

The Dashboard now preserves the last received host cycle on its original worker
and incarnation. The closed wait contract includes model lane configuration,
provider, operator and source waits; the cycle issue contract includes listing,
recording and delivery failures. Details and original request IDs survive.
This is a cycle observation, not a complete attempt history, a current provider
probe, a successful result, cleanup confirmation or execution authority.

Absent cycle data stays absent (including retained worker records). A malformed
cycle becomes an unreadable diagnostic while the original worker, completed
observations, package action schema and remaining snapshot stay available.
The worker table displays a read-only detail per original incarnation; replacement
workers receive only their own cycle. Failure/wait counts are visible in the
collapsed summary. No retry, redispatch, new polling loop or action is added.

Actual verification: the six explicitly named Dashboard suites pass (98 cases),
and `pnpm exec tsc --noEmit` exits0. `dashboard-vitest.txt` retains the verbose
execution log. The new API cases exercise the full snapshot boundary for all
host wait/issue variants, malformed diagnostics, absence/zero distinction and
replacement ownership. The panel cases exercise decoded data displayed under
its original worker, preserved rows and absence of incidental action dispatch.
Existing refresh/workspace ownership and installation consumer suites are included.

This change does not modify or build OCaml. Producer/TUI comparisons are source
inspection, not an HTTP run. No actual browser, real model, native TUI, live
installation or complete request-to-cleanup timeline was observed. G03 remains
partial and the 54-item goal is not declared complete. G01 #44803 and G04 #44810
have different frozen execution candidates; their results do not certify this
Dashboard source. Formal current-head approval and integration remain separate.

Independent source/contract reviews bind the complete bottom diff, including
worklist/changelog, and find no P0–P2. They did not rerun tests and are not
formal GitHub approvals.

Retained-cycle boundary: the current Runtime adds host_requests to live_json,
not the persisted entry_json. Production retained records can therefore lack
this cycle. The supplied-retained-row panel case proves UI owner isolation for
received data, not that a real detach/restart retains host cycle history. A
durable original request/attempt timeline remains required by G03; this fix
only stops discarding and misreporting observations that the host sends.

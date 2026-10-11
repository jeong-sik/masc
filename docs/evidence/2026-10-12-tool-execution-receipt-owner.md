# Tool execution result ownership candidate

Base: 0a14dc0e20ca3dfd792b355248cd97dfb849a534. Parent schema unit has unresolved independent P2 findings: normal dev-token bootstrap ownership and mounted executor reload. This candidate is not approved for integration.

Two fixtures failed before the execution change: an old execution result appeared under a replacement selection, and a previous credential execution blocked a replacement execution. RED: /tmp/tool-execution-owner-red-20261012.log.

Execution captures arguments before reactive effects, exact execution slot, credential revision and selection incarnation. Old results/errors/toasts cannot publish under a new selection; old cleanup cannot clear replacement execution. Authentication revokes visible execution ownership without claiming server cancellation.

Focused mocked-transport consumer verification passed three suites / 80 tests: /tmp/tool-execution-owner-focused-20261012.log. Initial noEmit failed because the fixture factory widened schema type; adding its real McpToolSchema return annotation resolved this; final noEmit exited 0. No actual provider, UI screenshot, CI, formal approval or deployment evidence. Normal bootstrap admission for execution remains to be verified together with the parent finding.

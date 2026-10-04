# Release verification scope

The release gate answers whether the frozen product can be installed and its
core user flows work. It is not automatically every test in the repository.
This document defines the target split; it does not change the current root
`@runtest` RC or retroactively excuse its failures. Implement the split in a
separate reviewed change for the next release.

## Required on every candidate

| Surface | Required outcome |
| --- | --- |
| Build and package | Type/build checks, packaged configuration and shipped assets are valid. |
| Installation | Each supported platform installs the exact candidate; installed binary starts and answers health and MCP smoke. |
| Keeper chat | Send input during tool activity without losing prior output; messages remain ordered and attached to the intended Keeper; streaming completion/error/cancellation is observable. |
| Memory | Relevant stored evidence is selected and actually included in the model request; empty or failed recall is distinguishable. A memory-status label alone is not proof of injection. |
| Durable operations | Core accepted requests and results survive replay; cancellation and permissions do not silently authorize or duplicate effects. |
| Runtime route | The configured supported route can complete a representative turn; adapter protocol and failure semantics are exercised without requiring every model/account combination live. |
| Publication | Tag, receipt, checksums and published assets identify the same verified candidate. |

Existing suites are evidence inputs, not a complete selection manifest. Examples
include `test_tui_keeper_chat_live.ml`, `test_keeper_chat_delivery_identity.ml`,
`test_keeper_chat_operation_http.ml`, `test_keeper_turn_driver_failover.ml` and
`test_tui_memory_recall_state_pty.py`. Inspect their actual assertions before
selecting them; names and a green status cannot establish missing coverage.

## Required when the release changes that surface

- Keeper selection: A-to-B selection must not mix A's chat or tools into B.
- Server/workspace connection: reconnecting or selecting another workspace must
  discard stale data and reject writes authorized only by the old workspace.
  This is what "workspace transition" means; it is not every possible UI tab.
- Layout: preserve readable input/actions at representative supported sizes and
  actual layout breakpoints when rendering changes.
- Portraits/items, optional Lanes, runtime setup, connectors and other shipped
  surfaces: test the changed flow and its direct consumers.
- Security, authority, persistence and packaging changes: trace the affected
  boundary and all direct consumers even when the visible flow is optional.

The frozen included changes determine this scope. A feature already included
in the release does not become untested merely because its tests are expensive.

## Separate from mandatory RC behavior

| Test class | Appropriate lane |
| --- | --- |
| Source wording, occurrence counts or ordering of source fragments | Remove or replace with actual behavior/protocol evidence; do not use as release behavior proof. |
| Log-analysis script and benchmark-tool implementation tests | Run when those tools change, separately from product readiness. Examples: `test_tool_call_sequence_miner.py`, `test_benchmark_scripts.py`. |
| Exhaustive screenshots, width sweeps and accessory combinations | Rendering/feature validation when relevant. Keep representative interaction and boundary checks in the selected release scope. |
| Long-running performance and live-provider comparisons | Dedicated measurement when an explicit performance/runtime claim or affected contract depends on them. The required performance SLO readiness evidence still applies to every release-ready verdict. |

[Release evidence](../RELEASE-EVIDENCE.md) retains the mandatory quantitative
readiness bundle, including [performance SLO results](../PRODUCTION-READINESS-GATES.md#gate-3-performance-slo).
Separating extended comparisons does not waive that evidence. If the performance
harness cannot run, record `blocked` or `not evaluated`; missing data is not green.

For example, `test_tui_region_baseline_pty.py` includes click targeting and pane
boundaries, not just pictures. Preserve that functional coverage before
separating its broad visual sweep. Do not exclude a suite by filename alone.

## Selection and evidence

Before freeze, the owner records the core scenarios and changed-surface scope,
their actual verification targets and environment limits in the release PR.
All required stages run against the same candidate SHA. Diagnostic focused
passes do not replace this complete selected release gate. Review missing
coverage and test removals independently; do not reclassify a failing test after
the fact merely to ship. Infrastructure failures and product failures remain
distinct, and unmeasured provider/production behavior stays unverified.

See [release freeze](RELEASE-FREEZE.md) and [release evidence](../RELEASE-EVIDENCE.md).

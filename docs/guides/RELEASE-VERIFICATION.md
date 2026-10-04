# Release verification scope

The release gate answers whether the frozen product can be installed and its
core user flows work. This is an artifact-publication verdict; production-ready
requires every gate in [Production readiness](../PRODUCTION-READINESS-GATES.md),
including quantitative Keeper fleet, performance SLO and Agent Core boundary
evidence. Missing production data remains blocked or not evaluated. The artifact
gate is not automatically every test in the repository.
This document defines the target split; it does not change the current root
`@runtest` RC or retroactively excuse its failures. Implement the split in a
separate reviewed change for the next release.

## Required on every candidate

| Surface | Required outcome |
| --- | --- |
| Build and package | Full development/release type and compile checks, including Agent Core, dashboard payload consumers, packaged configuration and assembled distribution assets are valid. |
| Installation | Each supported platform installs the exact candidate; installed binary starts and answers health and MCP smoke. |
| Keeper chat | Send input during tool activity without losing prior output; messages remain ordered and attached to the intended Keeper; streaming completion/error/cancellation is observable. |
| Memory | Relevant stored evidence is selected and actually included in the model request; empty or failed recall is distinguishable. A memory-status label alone is not proof of injection. |
| Durable operations | Core accepted requests and results survive replay; cancellation and permissions do not silently authorize or duplicate effects. |
| Runtime route | The configured supported route can complete a representative turn; adapter protocol and failure semantics are exercised without requiring every model/account combination live. |


Existing suites are evidence inputs, not a complete selection manifest. Examples
include `test_tui_keeper_chat_live.ml`, `test_keeper_chat_delivery_identity.ml`,
`test_keeper_chat_operation_http.ml`, `test_keeper_turn_driver_failover.ml` and
`test_tui_memory_recall_state_pty.py`. Inspect their actual assertions before
selecting them; names and a green status cannot establish missing coverage.

## Publication integrity after verification

Candidate verification assembles and checks its distribution assets; public
publication consumes those verified assets afterwards. Before publication,
validate the candidate receipt, source SHA, distribution and checksums. After
publication, verify that the tag and public assets identify that same verified
commit. Public assets are not a precondition for an unpublished candidate to
pass its verification gate. Publication is not production-readiness proof.

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
| Log-analysis script and benchmark-tool implementation tests | Run when those tools change, separately from product readiness. Example: `test_tool_call_sequence_miner.py`. |
| Exhaustive screenshots, width sweeps and accessory combinations | Rendering/feature validation when relevant. Keep representative interaction and boundary checks in the selected release scope. |
| Quantitative Keeper fleet, performance SLO and generic Agent Core boundary review | Dedicated production-readiness lanes; all remain mandatory for a production-ready claim. The artifact gate separately requires full Agent Core compilation/types and affected runtime protocol behavior. |
| Extended live-provider/model comparisons | Dedicated measurement when the changed contract or explicit runtime claim depends on them; representative supported-route behavior remains required on each candidate. |

For example, `test_tui_region_baseline_pty.py` includes click targeting and pane
boundaries, not just pictures. Preserve that functional coverage before
separating its broad visual sweep. Do not exclude a suite by filename alone.

## Selection and evidence

Before freeze, the owner records the core scenarios and changed-surface scope,
their actual verification targets and environment limits in the release PR.
Full compilation/type checks, four-platform installation and the complete
declared essential behavior profile run against the same candidate SHA. A
reviewed versioned profile must record its exact suites and identity in the
candidate receipt; it cannot be reduced after a failure to manufacture a pass.
Full repository regression remains a separate manual validation lane when the
selected-profile architecture is implemented. The current workflow still runs
root `@runtest`; this document does not assert that #41156 is integrated.
Diagnostic focused
passes do not replace this complete selected release gate. Review missing
coverage and test removals independently; do not reclassify a failing test after
the fact merely to ship. Infrastructure failures and product failures remain
distinct, and unmeasured provider/production behavior stays unverified.

See [release freeze](RELEASE-FREEZE.md) and [release evidence](../RELEASE-EVIDENCE.md).

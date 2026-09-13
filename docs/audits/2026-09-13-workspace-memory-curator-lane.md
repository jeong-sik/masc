# Workspace curator execution lane

Successful ordinary or source-bound memory commits wake one server-owned
curator per canonical workspace. One execution may run while further commits
coalesce into one pending inventory read. The running request retains its
original attributed sources; the pending request reads the latest committed
stores, including changes from another Keeper. A retained successful exact run is reusable only for the same
inventory, rendered prompt, output schema, frozen catalog generation and ordered
slot identities, and only after reading and validating its referenced proposal.
Prompt errors cannot reuse an earlier success. Startup
reconciles current stores with those execution receipts, including commits that happened
while the process was down.

The operator must explicitly configure
`[runtime.exact_output_lanes.workspace_curator_exact]` with `slots` naming
existing admitted catalog targets. General runtime provisioning does not enable
this lane or choose a model. CLI tails have no workspace-owned execution
adapter in this unit and produce an explicit configuration/execution error;
they are not silently ignored. After changing configuration, the next committed
memory change or server startup observes it. This unit does not claim an
immediate configuration-change wake.

`workspace_memory_curator` is a normal Prompt Registry Markdown asset with the
`workspace_memory_inventory` template variable. File/override resolution occurs
once for a captured inventory. The exact registry records the same effective
template and rendered prompt passed to the provider, before provider dispatch.
Missing/invalid prompt configuration produces a failed run, not an in-code
fallback prompt. The request contains the full original inventory; this first
runtime unit does not implement the standalone importer's multi-step grouped
synthesis or silently truncate sources to fit a provider.

The existing proposal codec validates complete source coverage and bindings.
Successful results use the existing immutable proposal store and are available
through the existing API and `keeper_workspace_memory_read`. Results remain
`model_proposed`, with semantic verification explicitly unperformed. Current
source file hashes are not revalidated by collection; source revalidation is
still performed by its existing recall/tool producers. This is committed-memory
change delivery, not an arbitrary file watcher or automatic memory promotion.

The standalone lane matrix and run inspector include Workspace Curator. Its
actor is the canonical workspace path, rendered as workspace metadata. It is
excluded from Keeper owner joins, Keeper links and Keeper turn-inspector lists.
Model failures remain failed exact runs and do not write an empty successful
proposal. They do not block a later committed change. The change notification is
in-process; journal append is not treated as authoritative delivery. Individual
source snapshots are not claimed to form an atomic whole-workspace snapshot.

Validation boundaries:

- `test_workspace_memory_curator_lane` drives real memory writes and proposal
  readback with an injected provider: cross-Keeper coalescing, immutable running
  input, unchanged/restart reconciliation, failure recovery and directory aliases.
  Native execution belongs to CI; local OCaml validation is parse-only.
- Dashboard mounted tests verify the workspace row has no fabricated Keeper
  link or Keeper API request. `scripts/verify-workspace-curator-owner.mjs` renders
  the source component with synthetic API responses and writes a browser receipt
  and screenshot. The final source-browser receipt and directly inspected PNG
  are in `docs/evidence/2026-09-13-workspace-curator-source-browser/`; the
  superseded fixture/cache observations remain alongside them. Three mounted
  UI/API suites passed 38 tests. This browser probe does not exercise a native
  worker or an installed runtime.
- Real configured model output, semantic quality, native CI and installed
  commit-to-proposal-to-Keeper behavior must be reported separately.

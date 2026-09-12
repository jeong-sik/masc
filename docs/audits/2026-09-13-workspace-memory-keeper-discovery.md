# Keeper discovery of workspace memory proposals

The curator's immutable archive was reachable only through an explicit discovery
call. That call lists every historical proposal, including all claims and snapshot
metadata. The new publication descriptor gives each autonomous Keeper turn a
single exact read target without injecting model-written claims into the briefing.

## Publication and interpretation

`<base-path>/.masc/workspace-memory/publication.json` references the proposal's
content-derived ID and captured source-context SHA-256. The descriptor and the
referenced proposal are checked on read, including the proposal's existing strict
schema and content hash. Reading never enumerates historical proposals. Missing,
unavailable, and available are separate typed observations. Dangling parent
aliases, corrupted descriptors, and missing/corrupt target proposals are errors;
they never select another historical proposal or report an empty archive.

The curator publishes after saving the immutable proposal, before recording its
exact-run completion. Publication therefore proves only a readable saved proposal,
not successful exact-run completion or semantic truth. A cached successful run
reconciles a missing descriptor using its validated saved output. Invalid existing
descriptors cannot be overwritten by cache reconciliation. A failed provider call
preserves the previous publication. A failed write before rename preserves it too;
a failure after rename may leave the new descriptor visible, and the error is
returned without rolling back to an older proposal. Cancellation preserves the
original backtrace. Successful writes are read back. This uses the existing strict
writer's process-restart sync contract, not a power-loss guarantee.

The published context may differ from live Keeper memory. The briefing explicitly
states `not_checked_against_current_memory`, `model_proposed`, and
`semantic_verification: not_performed`; it does not compute current-source equality
or promote any claim. Source owners, facts, disagreements, changes, invalidations,
and store gaps remain in the immutable proposal available through the existing
`keeper_workspace_memory_read` exact-ID call.

## Turn and preview integration

`Workspace_memory` is an ordered typed context layer. The autonomous turn reads
one publication and passes that observation to the pure prompt renderer. Only
validated SHA identities and the Prompt Registry read affordance are injected.
Neither claims nor arbitrary filesystem error text enter the prompt. The dynamic
world frame is not appended to conversation history. Dashboard prompt previews
read the same publication path and use the same renderer.

This does not wake a sleeping Keeper, require a read every turn, select semantic
relevance mechanically, or claim that a Keeper adopted or verified the contents.
Direct-message prompt assembly is outside this slice. The existing history-list
tool behavior remains available, but the briefing points directly to one ID.

## Validation scope

Added feature cases cover publication/readback, exact attributed source retrieval,
ignoring an unrelated corrupt historical file, replacement while retaining the
archive, failed publication, invalid descriptor/target and dangling-parent errors,
no history fallback, held curator input and later publication, provider failure
with changed live facts, and dynamic-context/preview separation from durable user
messages. The layer completeness suite includes the new constructor.

Local validation is OCaml parse-only and diff checks. No local native build,
typecheck, model execution, browser run, installation, or native test execution is
claimed for this slice. Native suites must run in CI on the reviewed commit.

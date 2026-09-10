# Keeper access to workspace memory

`keeper_workspace_memory_read` is an always-available Keeper base tool. Calling
it with `{}` discovers saved curator proposal IDs and their claims, conflicts,
exclusions, source-to-snapshot bindings, snapshot attribution and memory gaps.
Calling it with `{"id":"<returned ID>"}` returns the complete durable proposal.
An absent ID returns `found:false`; invalid IDs and unreadable/corrupt storage
produce typed failures rather than an empty memory answer.

The tool uses the workspace proposal store directly through the Keeper's
resolved `Workspace.config.base_path`. It does not read another workspace or
acquire an HTTP operator token. Its catalog permission is `CanReadState`, and
its canonical in-process descriptor is read-only and concurrent. Standard
Keeper dispatch, schema validation and model tool publication carry it.

Every returned proposal remains `model_proposed`, with semantic verification
explicitly unperformed. Reading does not mutate Keeper memory. A Keeper can
use the shared evidence in a task, cite the original source owners, preserve
disagreement, and choose whether further verification is needed. This unit
does not inject proposals automatically into every turn or prove that a live
Keeper has yet chosen to use them.

The real Keeper dispatcher test saves two owners' conflicting retraction
evidence, discovers it, reads the complete envelope, and distinguishes missing,
invalid and corrupt IDs. Catalog/schema publication and tool-matrix fixtures
include the new tool. No local build was run; CI and deployed behavioral
evidence remain required before claiming live reuse.

Schema cost is explicit: CI34401018154 measured 98,808 bytes across 112 tools,
including the new 776-byte reader. Existing convention permits growth with the
feature that buys it, so the ceiling increases by that exact delta, preserving
132 bytes of prior headroom. No tool is hidden or deferred to satisfy the test.
The production schema test now prints this reader's serialized contribution.

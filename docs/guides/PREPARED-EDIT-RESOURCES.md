# Existing-file Edit resources

`Keeper_tool_filesystem_runtime.prepare_edit` resolves already-translated local
Patch arguments and pins existing target/source parent directory capabilities
on the caller's switch. Preparation neither reads source bytes nor writes,
authorizes an effect or supplies safe replay evidence. Missing resources,
endpoint-owned trees and other modes stay on their ordinary Serial path.

The opaque result carries exact input and original workspace, Keeper, Task and
trace identity. Its conservative directory claims use physical device/inode
identities and complete ancestry, including ancestors above an allowed root.
Sibling directories can be independent; equal or nested directories, aliases
and overlapping source/target parents conflict. A resource claim cannot be
supplied by a Skill document or provider JSON.

Pass the opaque result explicitly as `prepared_edit` to the existing write
consumer. It resolves current confinement, checks owner/input/root/parent and
ancestry bindings, and consumes the pinned target/source parents. It opens the
source at execution rather than freezing the source inode during preparation,
so a later patch can read the preceding patch's atomic replacement. Existing
Gate, sandbox containment, external-resource lease, publication recovery,
patch application, snapshots and effect evidence remain on the execution path.
A different input, Task/trace or parent cannot spend this preparation.

The frozen public Keeper bundle registers resource admission for canonical Edit
descriptors. It translates the model input through the descriptor's existing
policy and requires the original Keeper, Task, trace and turn source. Missing
source or unavailable preparation retains ordinary Serial execution, including
its validation and failure observation. No tool name or provider-supplied path
claim decides admission.

The prepared handler crosses the ordinary bridge, Handler, dispatch and write
consumer with the same opaque value. It retains the original source snapshot
and actual SDK invocation. Each dispatch forks the then-current turn Gate
context and contributes its result to the turn aggregate, so a later conflicting
wave sees predecessor results without concurrent siblings sharing a mutable
call context. Physical call receipts still commit through the ordinary hooks.

The feature suite `test_keeper_prepared_edit` covers actual filesystem/SDK
scenarios: disjoint Edit authorization boundaries overlap, conflicting patches
consume predecessor bytes, directory aliases and ancestor directories retain order, changed input/owner
or parent cannot write, Manual Gate retains containment and the existing internal
playground authorization, and caller cancellation leaves no effect and permits
a later call. Public bundle scenarios additionally exercise actual hooks and
physical Task/trace/execution receipts, conflicting public patches and missing
source admission. Execution evidence must name the tested head and scenario;
authored source and parse-only checks do not prove execution.

Named Inline Skills aggregate these claims when every leaf is an ordinary Edit,
every input is resolved before execution and the original source is available.
The opaque preparation owns the exact instantiated plan, each original member
node, its validated model input and its file preparation. It crosses the normal
Skill activation, bridge, Executor, Handler, receipt and result-publication
boundaries. A mismatched plan/node/input is refused before that leaf dispatches;
it cannot fall back under claims for different resources. All leaf footprints
participate, including later leaves. Within that exact plan, disjoint prepared
leaves can overlap. Every conflict with an earlier leaf in dependency-layer
order adds an ordering edge, including conflicts with owners already waiting
on another owner. Explicit dependencies remain in force. Failed or skipped
resource predecessors stand down their successors, while unrelated branches
follow the plan's failure policy. A newly ready resource successor uses those
predecessor completions for the existing fail-fast decision. Each leaf captures
immutable Gate evidence before entering its ordinary handler and contributes
its result to the original invocation and turn aggregates.

The producer releases earlier file preparations if it cannot transfer the
complete aggregate, including on cancellation. Released file preparations
cannot execute; their owning switch remains responsible for final cleanup.
Output-dependent paths, mixed plans, compiled children, Async and Terminal keep
their ordinary admission. Published-snapshot fixture scenarios cover two Inline
Skills' actual effects, overlap and conflict waves, physical leaf/run receipts,
activation ownership, a conflict with direct public Edit, and a later leaf's
shared footprint. Single-Skill scenarios additionally cover inner overlap,
physical alias order, explicit dependencies, failed conflict predecessors with
a successful disjoint sibling, and cancellation followed by a fresh invocation.
These require their own executed-head evidence.

No general Bash,
endpoint write, Async admission, cross-process exclusion or measured model
preparation speedup is supplied by directory claims.

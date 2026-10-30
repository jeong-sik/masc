# Existing-file Read/Edit resources

`Keeper_tool_filesystem_runtime.prepare_edit` resolves already-translated local
Patch arguments and pins existing target/source parent directory capabilities
on a preparation-owned child switch. Preparation neither reads source bytes nor writes,
authorizes an effect or supplies safe replay evidence. Missing resources,
endpoint-owned trees and other modes stay on their ordinary Serial path.

The opaque result carries exact input and original workspace, Keeper, Task and
trace identity. Entry claims bind the physical parent and lexical leaf;
additional object claims retain device/inode alias ordering. Each claim keeps
complete physical directory ancestry, including ancestors above an allowed
root. A shared parent alone permits distinct entries. Overlapping claims
conflict when either is a write; overlapping reads can run together. A resource claim cannot be
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

Named Inline Skills aggregate these claims when every leaf is an ordinary Read
or Edit and at least one leaf is Edit,
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
cannot execute. Release ends the child switch and waits for its directory
cleanup; the caller's switch also owns that lifecycle when a preparation is
never executed. Directory release uses switch cleanup on every platform,
including macOS where directory capabilities do not expose a direct close operation.
Output-dependent paths, other effect mixtures, compiled children, Async and Terminal keep
their ordinary admission. Published-snapshot fixture scenarios cover two Inline
Skills' actual effects, overlap and conflict waves, physical leaf/run receipts,
activation ownership, a conflict with direct public Edit, and a later leaf's
shared footprint. Single-Skill scenarios additionally cover inner overlap,
physical alias order, explicit dependencies, failed conflict predecessors with
a successful disjoint sibling, and cancellation followed by a fresh invocation.
These require their own executed-head evidence.

`prepare_read` binds existing regular files in the Keeper's own shared-mount
tree without reading content or initializing its sandbox bundle. Extra read
roots and endpoint-owned trees keep their ordinary backend and admission.
Prepared Reads carry only read claims and execute through the pinned owned
directory capabilities; they never fall back to a process or endpoint after
accepting that preparation. Current owner, exact input, selected backend,
confinement, parents and physical ancestry are revalidated before opening.
Line offsets, line limits, byte bounds and continuation fields use the same
Read projection. The returned `via` is `owned_capability`.

The shared implementation is `Keeper_prepared_file`; exact Inline plans bind
typed Read/Edit leaves through `Keeper_prepared_inline_files`. The opaque
operation token travels through Executor, Handler and runtime dispatch. Reads
open at execution, so the same entry's preceding atomic Edit is visible. An
Edit that replaces a symlink can be followed by a Read of that exact claimed
entry through its original pinned parent; a redirect to another new source is
refused. Read-only plans retain their ordinary admission. Gate and publication
recovery remain on the Edit consumer.

Mixed feature scenarios in `test_keeper_prepared_edit` cover two published
Skills sharing a real Read while their independent write boundaries overlap,
a Read after a same-file Edit, a Read after symlink-entry replacement, and
prepared Read owner/input/release and line-window behavior. These scenarios
also cover missing and nonregular Read resources retaining ordinary admission,
and streaming past a line larger than the Read byte bound or reaching EOF
before a large offset. These scenarios are authored source until executed for
the reported head. The fallback scenario observes ordinary handler selection
without launching its sandbox process; file preparation and cleanup remain real.

No general Bash,
endpoint write, Async admission, cross-process exclusion or measured model
preparation speedup is supplied by directory claims.

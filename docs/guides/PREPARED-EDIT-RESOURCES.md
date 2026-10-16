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

The feature suite `test_keeper_prepared_edit` authors actual filesystem/SDK
scenarios: disjoint Edit authorization boundaries overlap, conflicting patches
consume predecessor bytes, directory aliases and ancestor directories retain order, changed input/owner
or parent cannot write, Manual Gate retains containment and the existing internal
playground authorization, and caller cancellation leaves
no effect and permits a later call. Authored source and parse-only checks do not
prove these scenarios have executed.

This producer layer does not yet register resource admission on public MASC
Edit tools or aggregate it through outer Inline Skills. That integration must
thread the same opaque preparation through the actual descriptor, Handler and
Executor boundaries and verify published Skill behavior. No general Bash,
endpoint write, Async admission, cross-process exclusion or measured model
preparation speedup is supplied by directory claims.

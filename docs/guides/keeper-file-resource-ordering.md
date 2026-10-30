# File resources in Read/Edit/Write Skills

Existing-file Edit calls on a shared-mount Keeper prepare their actual file
resources before execution. Named Inline Skills also prepare their resources
when every leaf is an ordinary Read, Edit or Write, at least one leaf is Edit or Write, and
all validated inputs and the original call source are available before execution.
Read preparation covers existing regular files in the Keeper's own shared-mount
tree. Other read roots and endpoint-owned trees retain their ordinary admission
and backend.

The producer pins the existing parent directories and identifies them by their
physical device/inode and complete ancestry. Its entry claims identify each
file entry by that physical parent and its leaf name:

| Resource | Access | Scheduling |
|---|---|---|
| Lexical replacement entry | Write | Wait for an earlier overlapping read or write. |
| Resolved source entry | Read | May overlap another read; wait for an earlier overlapping write. |

A prepared Read claims its lexical entry and resolved source entry as Read.
It can share those resources with other reads; an overlapping Edit still orders
it after the earlier owner. Skills and model inputs cannot supply these claims.

Distinct entries may overlap in the same directory or nested directories. Their
shared directory is ancestry, not an occupied write resource. Each entry retains
its parent and complete physical ancestry, so a producer that explicitly claims
a whole directory still conflicts with its entries. Direct Edit and eligible
named Inline Read/Edit/Write Skills transfer their producer-owned claims through
`Tool.ordinary_descriptor_scoped`. Directory aliases of the same entry have the
same physical identity.

Write-only and mixed Read/Write Skills use the same aggregate transfer as Edit
Skills. Each Write retains its existing producer's target/source entry and
object claims, or physical parent/ancestor claims for missing targets and
directories. Distinct prepared aggregate resources may overlap in the outer SDK
batch; actual conflicts still order. No file or directory is created during
preparation. A partial or unsupported aggregate releases its acquired resources
and retains ordinary execution. Dynamic inputs still bind when ready inside
their original plan; they are not guessed to enable aggregate preparation.
Source Before/After and unexecuted scenarios are recorded in the
[Write aggregate audit](../audits/2026-10-19-write-aggregate-resources.md).

Each Edit also declares the lexical target object as Write and the source
object as Read, identified by physical device/inode. A prepared Read claims
both objects as Read. These additional claims
preserve the backend's existing mutation lease for hard links and unify spelling
aliases on filesystems that resolve them to one object. They do not guess case
or Unicode normalization rules.

Patch opens the current source and atomically replaces the lexical target
entry. Its resource identity therefore uses the parent and leaf, rather than
the file inode: an earlier replacement must still order a later patch to the
same entry. Hard-link aliases retain backend mutation ordering even though
replacing one entry leaves the original inode reachable through the other entry.

An Edit through a file symlink reads the resolved source and atomically replaces
the lexical target entry. Two such entries can read one shared original
concurrently: each target receives its own replacement, and the original remains
unchanged. If an earlier Edit replaces that original, the later read waits and
opens its current bytes after the replacement.

A prepared Read opens its source at execution, so a Read ordered after an Edit
sees that replacement. If the earlier Edit replaced the exact claimed symlink
entry with a regular file, the Read uses that same pinned lexical parent.
A redirect to another source is refused. Accepted Read preparation executes
through the pinned owned-directory capabilities and reports `owned_capability`;
it does not switch backends after accepting those resources. Line windows and
byte bounds keep the ordinary Read projection.

Resource claims describe access to individual resources. A call carrying a Read
claim can also carry Write claims and retains its effectful permission contract.
The existing owner/input checks, confinement, Gate, publication recovery and
cancellation cleanup still run. A claim grants no permission to replay an
unknown effect. The directory capabilities live only for the current execution;
they are not durable continuation authority.

The ordinary schedule handles an unsupported or unavailable preparation.
Prepared plans keep their explicit dependency and branch-failure rules in
addition to resource ordering. This producer covers direct existing-file Edit
and eligible named Inline Read/Edit Skills. Ad hoc `keeper_composition_run.recipe`,
output-dependent file inputs, Async and Terminal plans retain their ordinary
admission. Other tools require their own concrete resource and continuation
contracts. See [Read/Edit preparation](PREPARED-EDIT-RESOURCES.md) for capability
lifetime, fallback and execution boundaries.

Measure task preparation and completion under the same task/provider/tool
conditions before reporting a speedup. Independent entries and shared reads
remove unnecessary ordering edges; they do not establish a fixed latency
improvement.

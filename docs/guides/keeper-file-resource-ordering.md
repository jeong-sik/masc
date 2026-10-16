# File resources in parallel Edit calls

Existing-file Edit calls on a shared-mount Keeper prepare their actual file
resources before execution. Published Inline Skills made only of those Edits
use the same producer and resource ordering when their original source context
and validated inputs are available.

The producer pins the existing parent directories and identifies them by their
physical device/inode and complete ancestry. Its entry claims identify each
file entry by that physical parent and its leaf name:

| Resource | Access | Scheduling |
|---|---|---|
| Lexical replacement entry | Write | Wait for an earlier overlapping read or write. |
| Resolved source entry | Read | May overlap another read; wait for an earlier overlapping write. |

Distinct entries may overlap in the same directory or nested directories. Their
shared directory is ancestry, not an occupied write resource. Each entry retains
its parent and complete physical ancestry, so a producer that explicitly claims
a whole directory still conflicts with its entries. No producer does so today:
`Tool.ordinary_descriptor_scoped` is called only by direct Edit and by Edit-only
Inline Skills, and both claim entries. Directory aliases of the same entry have
the same physical identity.

Each call also declares the lexical target object as Write and the source
object as Read, identified by physical device/inode. These additional claims
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

Resource claims describe access to individual resources. A call carrying a Read
claim can also carry Write claims and retains its effectful permission contract.
The existing owner/input checks, confinement, Gate, publication recovery and
cancellation cleanup still run. A claim grants no permission to replay an
unknown effect. The directory capabilities live only for the current execution;
they are not durable continuation authority.

The normal Serial path handles an unsupported or unavailable preparation.
Prepared plans keep their explicit dependency and branch-failure rules in
addition to resource ordering. This producer covers existing-file Edit and its
Edit-only Inline Skills; other tools require their own concrete resource and
continuation contracts.

Measure task preparation and completion under the same task/provider/tool
conditions before reporting a speedup. Independent entries and shared reads
remove unnecessary ordering edges; they do not establish a fixed latency
improvement.

# File resources in parallel Edit calls

Existing-file Edit calls on a shared-mount Keeper prepare their actual file
resources before execution. Published Inline Skills made only of those Edits
use the same producer and resource ordering when their original source context
and validated inputs are available.

The producer pins the existing parent directories and identifies them by their
physical device/inode and complete ancestry. It declares each directory's
access from the operation that will consume it:

| Resource | Access | Scheduling |
|---|---|---|
| Parent of the lexical replacement target | Write | Wait for an earlier overlapping read or write. |
| Parent of the resolved source file | Read | May overlap another read; wait for an earlier overlapping write. |

Overlapping directories are the same physical directory, or an ancestor and
descendant. A shared ancestor alone permits independent siblings. Directory
aliases retain the same physical identity. When the target and source have the
same parent, its write claim still orders the Edit against other overlapping
accesses. Claims cover directories, so different files in the same directory
can still conflict.

An Edit through a file symlink reads the resolved source and atomically replaces
the lexical target entry. Two such entries in separate target directories can
read one shared original concurrently: each target receives its own replacement,
and the original remains unchanged. If an earlier Edit replaces that original,
the later read waits and opens its current bytes after the replacement.

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
conditions before reporting a speedup. Sharing reads removes an unnecessary
ordering edge; it does not establish a fixed latency improvement.

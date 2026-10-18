# Retain stable plan semantics while removing repeated graph scans

Source comparison base: `fdb7d27470cf68fd233e13ec74026e4b63b074d2` (#43805).
This is an implementation comparison, not an executed performance result.

## As-Is / To-Be

The executor already reuses one dependency-layer result across scheduling and
ready binding. Constructing that result still partitions every remaining node
at every layer. Each partition recomputes the node's semantic dependencies and
linearly searches an ever-growing completed list. Appending that completed list
adds further work. Long dependency chains therefore repeat preparation work
even though their source graph and node operands are immutable.

The replacement uses call-local immutable maps for pending counts, successors
and the next layer. It derives each node's semantic dependencies once. Settling
a layer decrements its outgoing edges and admits a dependent when its remaining
count reaches zero. An ordinal-keyed map retains original declaration order
within each layer, independently of node-ID spelling or adjacency traversal
order. The stored nodes are the actual plan objects, including private compiled
child operands; no descriptor, parameter, source or output authority is rebuilt.

| Boundary | Before | Source implementation |
| --- | --- | --- |
| Recompute semantic dependencies | Every remaining node at every layer | Once per node per call |
| Determine predecessor completion | Linear scan of completed IDs | Decrement original semantic edge count |
| Discover next ready layer | Partition all remaining nodes | Visit current layer's successor edges |
| Stable order | Filter original declaration order | Original declaration ordinal |
| Node/compiler identity | Original objects | Same original objects |
| Lifetime | One dependency-layer call | Same; no global or cross-execution cache |
| Execution/admission/resource semantics | Executor and original contracts | Same authority boundaries |

For a single-dependency chain of `n` nodes, the old source calls `dependencies`
`n(n+1)/2` times and compares completed IDs `n(n-1)(n+1)/6` times. The new source
calls it `n` times and releases `n-1` semantic edges, using ordered-map lookups
and updates instead of completed-ID scans. These are structural operation counts
for this specified graph, not timings or an executed benchmark.

After semantic dependency extraction, frontier construction and traversal use
`O((V+E) log V)` ordered-map work for `V` nodes and `E` distinct semantic edges.
Existing dependency/template deduplication costs and plan creation validation
remain outside that statement. Descriptor lookup, schedule-index lookup, input
validation and resource preparation also retain their own costs. This change
does not establish total preparation or end-to-end latency complexity.

## Invariants and scope

The abstract plan's constructors reject duplicate IDs, absent dependencies and
cycles. Parameter instantiation reconstructs through the same validated creation
boundary; native child operands must still match their original compiled nodes.
The frontier consumes only such validated plans. An absent successor adjacency
means a leaf, not a missing dependency recovery. This change adds no fallback
that admits invalid graphs, no node budget, heuristic dependency inference,
timer or mutable persistent cache.

The public result remains stable topological layers. The executor still owns
Serial/Concurrent/Terminal scheduling, original planned and batch indices,
Continue-independent failure behavior, cancellation, file preparation, resource
ordering and original Task/run/tool-use identity. The existing once-per-execution
graph reuse remains in place. No Keeper prompt, live configuration, effect
admission or durable async file-mutation permission changes.

## Authored evidence and limits

Three additional scenarios remain **unexecuted**:

1. A forward-declared typed producer/Read/Grep chain with repeated explicit and
   output dependencies, independent work and two Serial siblings retains actual
   node operands, declaration-ordered layers, scheduling metadata and outputs.
2. The same graph refuses its original first Serial node: its Serial successor
   stays unentered while independent typed work settles in canonical plan order.
3. Repeated exact async Skills precede their producers in declaration order.
   The public nested compiler retains child barriers and original operands;
   independently validated outputs bind distinct child arguments into their
   own newly instantiated plans. Invalid arguments and public operand forgery
   remain rejected by the original scenario's admission checks.

The first two use the real plan/executor with explicit dispatch fixtures. The
third extends the existing public compiler/argument-binding scenario. No
wall-clock thresholds, arbitrary graph-size limits, implementation-mirror
benchmarks or TUI wording/layout/PTY assertions are added.

Source validation is OCaml parsing-only plus diff/changelog checks. It does not
prove types, assertions, scheduling, file-resource continuity or measured speed.
No local build, typecheck, test execution, CI dispatch/watch, native/model run,
install/restart or real Before/After sample accompanies this layer. Independent
review of its current head remains pending.

The full goal remains active: original Ask/Task/useful work, frozen preparation,
ordinary/nested/dynamic/effectful resource continuity, held-job/shared-backend
work, TUI readability/visibility and matched real observations must retain their
own evidence, including failed, cancelled, interrupted and unfinished attempts.

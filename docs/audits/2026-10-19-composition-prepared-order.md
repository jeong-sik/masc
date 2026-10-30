# Exact prepared files: indexed predecessors and layer-local pending membership

Comparison base: `e298d532c06b0f16a0d2be7934c05cf49a5374be` (#43913).
This audit describes source structure. No runtime performance was measured.

## As-Is / To-Be

The exact aggregate file producer returns one resource-order row per original
validated plan node. Each row retains its original ordered predecessor list.
The executor previously found each row with `List.find_opt`, both during static
wave construction and later when awaiting ordered outcomes. Within every wave,
readiness additionally scanned all pending nodes and searched each node's ID in
the predecessor list. The original list scans repeated when a node waited for
another wave.

`Prepared_order` now owns one execution-local typed-ID map of those same
predecessor lists. Static wave construction and runtime outcome waits use the
same map. Each dependency layer also builds its own immutable pending-ID set;
readiness asks whether any original predecessor is still a member. A following
wave removes exactly the ready partition from that set. The final wave needs no
removal work because nothing remains pending.

The existing producer member map contains nodes and prepared operations, not
resource predecessor lists or current-wave membership. It cannot supply these
two distinct lookup operations. The new structures neither duplicate nodes nor
introduce a global cache or resource authority.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Prepared predecessor row lookup | Repeated linear row-list search | One map construction, keyed lookup |
| Predecessor values | Original ordered lists | Same list values, unmodified |
| Pending membership | Scan pending nodes, search each in earlier IDs | Search original earlier IDs in layer-local set |
| Wave node/contract/group order | Original list partition | Same list partition |
| Next-wave membership | Implied by waiting list | Same waiting list plus persistent set update |
| Missing row / cycle | Invariant error | Same error boundary and message |
| Runtime predecessor waits | Original ordered list | Same list retrieved through the shared map |
| Ready / descriptor-only modes | Their separate scheduling branches | Same branches, no new map or set |

## Ownership, order and effects

The producer still checks exact physical plan identity and original member
identity before returning resource ordering. Validated plan IDs are unique, so
the private map does not choose among duplicate producer rows. Node ID comparison
and equality retain the same string identity semantics. Map values refer to the
original predecessor lists; map iteration is never used to select a node, group,
wait, error or effect.

Each pending set starts from the original nodes of that one dependency layer.
Predecessors in an earlier layer are not pending in this layer. Partitioning
still visits the original pending-node list; the new predicate computes the
same pure membership relation with its operands reversed. Only ready members
are removed before another wave. Empty-ready cycle detection and missing-row
failure remain at their original points in that list-driven algorithm.

Scheduling metadata, required predecessor outcome order, failure tickets,
Fail_fast/Continue_independent rules, dynamic inputs, journal/admission boundaries,
Gate authorization, physical resource consumption, effect settlement and
switch-owned release retain their original paths. The Ready suffix/binding
mechanism and its direct static groups remain separate. A set entry or row
lookup grants no effect, source identity, replay or file authorization.

## Quantitative Before / After

For `N` prepared nodes and `Q` row lookups, row-list searches previously took up
to `O(Q*N)` key-equality work. The executor now pays an upfront `O(N log N)`
balanced-map construction and up to `O(Q log N)` keyed lookup work. This is an
upper-bound source comparison, not a count of all allocations or CPU time.

For a wave with `p` pending nodes, each readiness predicate formerly compared
pending entries with its earlier-ID list. It now probes the pending set while
visiting earlier IDs until a member is found. Set construction costs
`O(n log n)` for a layer of `n` nodes; nonfinal-wave removals also allocate
persistent tree paths. Those costs and retained references must be included.

For a one-layer 100-node plan with no conflicting resources, the static
scheduler previously visited 10,000 pending entries and made 5,050 row-list
ID-equality checks. Those specific scans disappear. It now performs 100 keyed
row lookups, 100 upfront map insertions and 100 pending-set insertions, with tree
key comparisons and allocation of their own. Empty earlier lists need no set
membership probes, and the final wave needs no set removals. Runtime row waits
also use the same map, but are outside this static example's count.

The example is not a benchmark or a net memory/speedup claim. Small plans can
pay more index overhead. Actual producer resource-pair comparisons, repeated
wave readiness evaluations, schedule/result construction and tool/provider calls
remain; this does not make the whole execution linear. Indexing happens at
executor entry and static scheduling still precedes journal/input admission, so
later-rejected executions retain this setup cost. An unused preparation or an
earlier plan rejection does not acquire these structures. Failed, cancelled,
interrupted and unfinished samples must remain in a matched actual cohort.

## Compound scenario and evidence limits

The existing original-member file scenario now has two real file chains: a
same-layer conflict on the independent file, and an explicit next-layer
successor on the first file. IDs differ from dependency/resource order. Both
the aggregate-prepared and Ready paths retain copied-member/foreign-plan refusal
checks, unchanged bytes before execution, committed predecessor bytes in both
files, and the complete four-effect physical receipt/Gate cohort with original
Task and parent identity. These are real producer/executor/handler boundaries,
not a map/set helper or invocation-count mirror. The scenario was not executed.

OCaml parsing only passed for the changed executor interface, implementation and
scenario; `git diff --check` passed. No build, typecheck, test, CI dispatch/watch,
native/model/PTY/controller/report run, install, restart, live write or own merge
was performed. Independent current-head source approval, compilation, physical
execution, useful Task progress, usable input, visible paint and actual matched
Before/After performance remain separate, unproven boundaries for this layer.

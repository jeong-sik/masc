# Exact Task Skill reference merge preparation

Source baseline: `e9e6690b7bdcc77cdf73996ccb6f897a323e0583` (#43822).
Scope: `Keeper_task_skill_turn.merge_rows`, used by observation reference
grouping, selected/unprojectable selection merge and retained-selection rebinding.
These consumers already preserve frozen source, descriptor and Task ownership;
this change targets repeated pure preparation work within that contract.

## As-Is and To-Be

For each candidate the old merge searched the accumulated reference list.
A new reference appended by copying that list; a repeated reference mapped
the complete list again to replace its matching row. With `R` distinct input
references, the search alone compared `R * (R - 1) / 2` accumulated references,
and append copied the same number of list cells.

Use a private immutable `Skill_reference.Exact_map` for each merge invocation.
The key compares canonical source id, package id, name and content revision,
and agrees with `Skill_reference.equal`. A new entry retains the original
candidate and a first-appearance ordinal. On the first repeated exact reference,
initialize an immutable owner-id set from that first row; accumulate each
repeated candidate's owners in the same set. Enumerate map values
and sort by those private ordinals, rather than exposing map key order or
performing a partial lookup/fallback to reconstruct the result. A unique row
stays the same object; a repeated pin emits its final canonical Task-owner list
once from the set. Repeated copies of the same owner do not enlarge that set.

| Source boundary | Before | After |
| --- | --- | --- |
| Locate candidate among `U` accumulated exact references | Linear reference search | Exact-reference map lookup |
| Add a new exact reference | Copy accumulated list to append | Add one map binding |
| Combine a repeated exact reference | Map over accumulated rows | Update one map binding |
| First original row and output reference order | Retained by list construction | Retained by first ordinal and original row |
| Same identity, different pinned revision | Separate exact-reference rows | Same: content revision is part of the key |
| Repeated exact pin Task owners | Re-sort growing union at every repeated occurrence | Incremental immutable set; same canonical list emitted once |
| Selected versus unavailable rows | Separate merge invocations | Same separation |

For `R` input rows and `U` distinct exact references, reference lookup/update
work changes from worst-case `O(R * U)` accumulated-list traversal to
`O(R log(U+1))` map work, plus `O(U log(U+1))` output ordering. Key comparison
cost depends on identity/revision lengths. The old all-distinct quadratic
append/search is removed; this is not a measured count of runtime comparisons.

Owner work is additional to that reference-work bound. If one exact pin
occurs `N > 1` times, each with a distinct single Task owner, old sorts receive
prefixes of sizes `2` through `N`; the new set accumulates `N` owner entries
and enumerates its sorted result once. For `K` original owner entries and `M`
distinct owners on a repeated pin, new owner work includes set construction,
`O(K log(M+1))` insertion and `O(M)` result enumeration. Repeated identical
owner ids do not cause a growing retained duplicate list or a final `K`-item
sort. Map/set allocation and final ordinal sorting still add overhead.
Snapshot discovery, reference resolution, catalog preparation, model/network
work, first useful work and UI paint have not been measured or newly removed.
No total CPU, memory, preparation percentage or speedup result is claimed.

## Ownership and authority

All index values and ordinals belong to this synchronous merge only. There
is no snapshot/turn/worker-spanning cache, generation, new read or numeric
control limit. Canonical key comparison is a typed domain operation, not a
serialized JSON/composite-string heuristic. `Identity_map` retains its existing
identity-only contract; `Exact_map` explicitly adds the pinned revision.

Repeated rows retain the first row's Skill/diagnostic/reason data and the same
final sorted/deduplicated Task-owner union. All four private callers provide
pure row accessors/reconstruction; no intermediate union is observable.
Selection descriptor-authority checks,
physical preparation compatibility and unreadable/stale pin handling remain
in their existing callers. A selected and refused row from different frozen
sources are not silently collapsed together; a later rebind resolves their
merged original exact requests against the supplied frozen snapshot.

## Authored scenario and evidence boundary

Extend the existing public frozen-binding scenario with repeated original
selections and original refusals, a second pinned revision of the same Skill,
and another Task owning the original pin. Both revisions must retain their
own Task identities; repeated original rows must retain the first frozen Skill
object and refusal owners. Rebinding to the original source must recover those
original owners and keep only the later Task's later pin unavailable, without
borrowing a mixed preparation. Existing cross-source collision, shared-pin and
unreadable-source scenarios remain relevant. No direct map-helper/count,
wording/layout/row-order/snapshot or PTY tests are added.

Scenarios remain unexecuted. OCaml parsing-only and diff/changelog hygiene are
the author checks; they do not prove typing or behavior. Independent source
approval, CI, native/model execution, install/restart, actual Task progress,
input/paint and matched Before/After timing remain separate and unverified.
Real cohorts must retain failed/interrupted/cancelled/unfinished attempts.

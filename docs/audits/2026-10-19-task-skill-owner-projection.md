# Task Skill surface projection by original owner

Source baseline: `5b142d68a9778a137353fb616d605b848a858820` (#43821).
Scope: `Keeper_task_skill_turn.exact_task_surfaces`, shared by direct turns,
unified turns and dashboard prompt preview. This is source work, not a measured
hotspot, latency comparison or runtime result.

## As-Is and To-Be

Preparation and executable capability projection were already shared within
this call. Afterwards, each observed Task scanned the complete selected and
unprojectable lists and searched every row's Task ids. For a pin shared by
several Tasks, the same projection availability lookup or unavailable-reason
construction ran again for each owner. Task-id deduplication also rescanned
and appended to an increasingly long list.

Create a private immutable map for the observed Task ids, retain the separate
observation-order list, then visit each original selection row once. Compute
its immutable surfaces once only if it has an observed owner, and distribute
them to those owners. Process selected rows before unprojectable rows and
reverse each final accumulator to retain the existing per-Task sequence.

| Source boundary | Before | After |
| --- | --- | --- |
| Task-id deduplication | Repeated linked-list membership and append | Map membership; reverse observation-order accumulator once |
| Selection-list passes for `H` distinct observed Tasks | `H` selected passes and `H` unprojectable passes | One pass of each list when `H > 0` |
| One selected row shared by `k > 0` observed owners | `k` availability lookups against the same projection | One availability lookup, distributed to `k` owners |
| One unavailable row shared by `k > 0` observed owners | `k` reason/surface constructions | One reason/surface construction, distributed to `k` owners |
| Row with no observed owner | Not emitted | Not projected or emitted |
| Observed Task without selected rows | Empty surface list | Empty surface list |
| New Task observation with reference absent from its frozen ownership | No fresh binding | Same: no borrowed pin or fresh binding |

For `P` selected rows each owned by all `H > 0` observed Tasks, per-row
availability projection is `H * P` before and `P` after. Distribution and final
output still require all `H * P` owned entries. Catalog lookup within each
projection, capability projection, snapshot preparation, serialization and
model/network work remain. No second catalog build was eliminated here.

Deduplicating `M` Task observations now costs `O(M log(H+1))`. Grouping also
sorts/deduplicates each row's original owner ids, checks map membership and
updates matching owners; its cost includes those owner memberships and output
size, not merely the number of selection rows. Maps, closures, singleton input
lists and accumulator reversal add overhead, especially for a single owner.
No total CPU, memory, preparation-percentage or speedup result is claimed.

## Frozen ownership and effects

The map lives only in this synchronous call and is not cached or stored in
selection, preparation, a worker or a later turn. It is initialized only from
current/recovered-current and held Task observations. Frozen selection owners
cannot introduce extra Tasks; repeated owner ids cannot duplicate one row for
one Task. All rows retain their exact reference, original availability/refusal
and original Task ownership. Surface records are immutable values, not effect
resources or an authority token.

The existing preparation, Tool descriptors, policy/deny/profile filtering and
capability projection still run once before grouping, including the no-Task
case. No pins are resolved again, no current observation replaces a frozen
selection, and no saved result authorizes execution. Retained preparation
observations and unreadable/stale source handling use their existing paths.
No new filesystem/network/model call, timer, TTL, cap, setting or Tool action.

## Authored scenario and verification boundary

Extend the existing public stale-pin projection scenario with shared original
Task owners, duplicate observations, an empty Task and a frozen owner absent
from observation. Both shared owners must keep the readable pin and stale-pin
refusal, without inheriting the outside owner's readable pin. Reprojecting
under a restrictive executable policy must withhold the readable pin for both
owners while retaining the stale refusal. A later observed Task cannot acquire
that pin from the earlier frozen selection. No row-order, layout, wording,
snapshot, PTY or helper/predicate-count assertions are added.

The scenario is authored and unexecuted. Only OCaml parsing and diff/changelog
hygiene are checked in this author session. Typing, assertion execution,
independent current-head approval, native/model runs, installed binary, actual
Task progress, visible UI and matched Before/After timing remain unverified.
Real cohorts must still retain failed, interrupted, cancelled and unfinished
attempts and distinguish preparation, acceptance and first useful work.

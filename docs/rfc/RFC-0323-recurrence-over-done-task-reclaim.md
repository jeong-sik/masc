# RFC-0323 — Recurrence over Done-task reclaim (model recurring coordination as new instances, not in-place reclaim of a terminal task)

- Status: Draft
- Area: `lib/types/types_core.ml` (`reclaim_policy`, `task_claim_decision`), `lib/workspace/workspace_task_lifecycle.ml` (`resolve_claim`), `lib/workspace/workspace_task_claim.ml`
- Builds on / touches: RFC-0314 (keeper recurring producer — the recurrence surface this RFC routes coordination work through), RFC-0034 (task oscillation mitigation — the cooldown band-aid this RFC makes unnecessary for this class), #23632 / task-1869 (the interim reclaim-on-Done change and its self-livelock guard)
- Evidence base: #23632 review (2026-07-08). The `Done` arm of `resolve_claim` let the completing actor re-claim its own `Allow_reclaim` task, unlike every other owned state; interim guard landed as `8fce078b2c` (`same_actor` → `Self_owned`).

## Problem

task-1869 (#23632) makes a completed task reclaimable through a per-task `reclaim_policy` enum (`Allow_reclaim` / `Block_reclaim` / `None`), so that "coordination-role tasks blocked from re-claim by completion" (6 `TaskError` fingerprints) can run again. The motivating need is real. The chosen model is not.

Reclaim-on-`Done` conflates two distinct concepts into one control:

1. **Recurrence** — "this coordination work should run again on a cadence." A property of the *work*, over time.
2. **Reclaim** — "this task was abandoned/held; a free actor may take it." A property of a *single task instance*, now.

Collapsing both into "a `Done` task with `Allow_reclaim` is claimable again" produced a concrete defect: the completer re-claims its **own** just-completed task (`complete → reclaim → complete …`), a self-livelock. The interim guard (`8fce078b2c`) restores the `same_actor → Self_owned` invariant that every other owned state already holds, which stops the busy-loop but leaves the conflation in place.

RFC-0034 (Draft) proposes a **cooldown** for sustained claim/release churn — a `cooldown_until` overlay that rejects claims for `COOLDOWN_SEC` after `cycle_count` reaches 10. That is symptom suppression on the same class (it lets the loop run to the threshold, then throttles). It does not remove the conflation, and it is on the CLAUDE.md "Cap/Cooldown" symptom list.

### Why this is a root issue, not a patch target

- The `reclaim_policy` enum is a per-task flag standing in for a temporal concept (recurrence). A flag on `Done` cannot express "run again *after interval N*", only "reclaimable *now*".
- Any guard on the reclaim path (same-actor, cooldown, dedup) is a bound on the busy-loop, not a model of the recurrence. Each is a band-aid that the codebase then learns from.
- RFC-0314 already provides the correct typed surface: a recurring producer that dispatches autonomous-repeat work on an `interval_sec`. Coordination work that must recur belongs there.

## Proposal

**Model recurring coordination work as RFC-0314 recurrence; keep terminal tasks terminal.**

1. **Recurrence creates new instances.** A coordination task that must run again is registered as an RFC-0314 recurring task (typed marker + `interval_sec`). Each due tick enqueues a **new** `Todo` task instance (linked to a recurrence parent for provenance); a free actor claims the fresh `Todo` through the ordinary path. The previously-completed instance stays `Done`.
2. **`Done` is terminal for every actor.** Remove the `Allow_reclaim` reclaim path from `resolve_claim`'s `Done` arm. A completed task is never re-claimed — not by the completer, not by a different actor. This subsumes the interim `same_actor` guard (which only closed the same-actor half).
3. **Retire the reclaim-on-`Done` policy surface.** `reclaim_policy = Allow_reclaim` no longer has a `Done` meaning. Either remove the variant or restrict it to non-terminal semantics with an exhaustive-match audit; `Block_reclaim` / `None` collapse to "terminal" for `Done`.

## Invariants (target)

- A terminal (`Done` / `Cancelled`) task is never re-claimed. Terminal is terminal.
- Recurring work is expressed as a **typed recurrence** (RFC-0314), never as a reclaim flag on a completed task.
- Re-running coordination work produces a **new task instance**; task identity is not reused across runs.

## Migration

1. **Interim (done — #23632 `8fce078b2c`).** `same_actor` guard on `Done + Allow_reclaim` stops the self-livelock. Cross-actor reclaim-on-`Done` still works, preserving task-1869's immediate need until recurrence replaces it. Labeled `WORKAROUND`, removal target = this RFC.
2. **Recurrence for the 6 fingerprints.** Route the coordination tasks that motivated task-1869 through the RFC-0314 recurring producer (new instances per interval) instead of reclaim-on-`Done`.
3. **Remove reclaim-on-`Done`.** Delete the `Allow_reclaim` arm in `resolve_claim`, retire the interim guard, and retire/narrow `reclaim_policy`. Guard the `Done` arm with an exhaustive match so no reclaim path can re-appear silently.

## Non-goals

- Cooldown / oscillation throttling (RFC-0034). Orthogonal; this RFC removes the need for it in the reclaim class rather than tuning it.
- Changes to the claim FSM for non-terminal states (`Todo` / `Claimed` / `InProgress` / `AwaitingVerification`) — unchanged.
- Cross-run task-identity reuse — explicitly rejected (invariant 3).

## Alternatives considered

- **Keep reclaim-on-`Done` + RFC-0034 cooldown.** Rejected: band-aid; the loop runs to the threshold before throttling, and the recurrence/reclaim conflation remains, so the pattern accretes.
- **Keep reclaim-on-`Done` + permanent `same_actor` guard (the interim).** Rejected as an endpoint: it blocks legitimate self-recurrence (the completer can never re-run its own coordination task, only a different actor can), and still conflates recurrence with reclaim.

## Verification

- Interim: `test_workspace_task_lifecycle.ml` — own `Done + Allow_reclaim` → `Self_owned` (added in `8fce078b2c`; fails before, passes after).
- Target: a `Done` task is never resolved to `Worker_claim` for any actor; a due recurrence produces a new `Todo` instance with a recurrence-parent link; exhaustive-match audit on the `Done` arm so a reclaim path cannot silently return.

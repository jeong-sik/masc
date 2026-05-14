---- MODULE KeeperCounterCausality ----
\* ── STATUS: FUTURE-DESIGN INVARIANT (not yet implemented) ────────────
\* This spec verifies an invariant a *future* feature must hold, not a
\* current runtime guarantee. As of 2026-04-20, re-verified 2026-05-12
\* (iter 76 — all four checks below still hold; see
\*  docs/tla-audit/kcc-r3-counter-causality-dormancy-reverified-2026-05-12.md):
\*   - rg "last_cause|last_incremented|last_bumped" lib/ -t ml -> 0 hits
\*   - .claude/plans/curried-moseying-whisper.md (referenced below): the
\*     repo has no .claude/plans/ tree, and rg "curried-moseying-whisper"
\*     finds only this spec -> the redesign plan is not wired anywhere
\*   - the dashboard counters exist (lib/dashboard/dashboard_http_keeper.ml
\*     keepers_dashboard_json serializes compaction_count from
\*     m.runtime.compaction_rt.count, a plain int) but compaction_rt
\*     (type compaction_runtime in lib/keeper/keeper_meta_contract.ml)
\*     carries no {last_incremented_at, last_cause_event} pair
\*   - KeeperCounterCausality is in no scripts/*.sh runner
\* The Agent Modal hover tooltip described in the redesign is not wired.
\* NOT in scripts/tla-check.sh runner -- this spec records the design
\* intent for when the cause-stamping extension lands; once the runtime
\* implements the field, drop this banner and add the spec to the runner
\* alongside the standard #8642-family OCaml<->TLA+ mapping comment.
\* See #8795 for the full audit.
\* ─────────────────────────────────────────────────────────────────────
\*
\* Keeper counter / event causality invariant.
\*
\* This spec models the minimal invariant the Agent Modal hover tooltip
\* depends on: every counter increment must be attributable to a single
\* causing event.  Concretely, if a counter reads N > 0, the keeper must
\* be able to name the event that produced the most recent bump.
\*
\* The redesign plan (`.claude/plans/curried-moseying-whisper.md`) adds
\* a per-counter {last_incremented_at, last_cause_event} pair serialized
\* from the state machine handlers, so a user hovering `compaction_count`
\* sees "last +1 at 14:22:03, cause: Compaction_completed".  If the
\* tooltip names an event that did not actually fire, or the counter
\* bumps without any causing event, observer trust collapses — the
\* failure mode this spec guards against.
\*
\* Guarantees:
\*   CausePresentWhenCounted — counter > 0 ⇒ last_cause ∈ CauserEvents.
\*   NoSpuriousBump          — every counter' = counter + 1 step is
\*                              labelled with a causing event.
\*   TypeOK                  — variables stay in their domains.
\*
\* Bug Model (feedback_tla-spec-audit-outcome-trichotomy):
\*   Clean cfg : Safety (TypeOK + CausePresentWhenCounted) holds.
\*   Buggy cfg : BuggyBumpWithoutEvent increments the counter but leaves
\*               last_cause untouched.  If last_cause was still "none"
\*               from Init, CausePresentWhenCounted MUST be violated.

EXTENDS Integers, TLC

CONSTANTS MaxCount       \* bound counter to keep state space finite

VARIABLES
    counter,
    last_cause

vars == << counter, last_cause >>

\* Subset of Keeper_state_machine.event that the Agent Modal counter
\* `compaction_count` listens to.  "none" is the sentinel for "never
\* bumped" and must not appear as a cause after the first bump.
EventKind == {
    "Compaction_completed",
    "Handoff_completed",
    "Turn_succeeded",
    "none"
}

\* Events that legitimately bump this counter.  Modelling a single
\* counter (e.g. compaction_count) keeps the spec focused; the same
\* pattern applies per-counter.
CauserEvents == {"Compaction_completed"}

TypeOK ==
    /\ counter \in 0..MaxCount
    /\ last_cause \in EventKind

Init ==
    /\ counter = 0
    /\ last_cause = "none"

\* ── Actions ─────────────────────────────────

\* A causing event fires: bump counter, stamp cause.  This is the only
\* clean path to incrementing the counter.
BumpFromEvent ==
    /\ counter < MaxCount
    /\ \E e \in CauserEvents :
         /\ counter' = counter + 1
         /\ last_cause' = e

\* A non-causing event fires: nothing changes for this counter.  Models
\* the (common) case where many events flow through the state machine
\* but only a specific subset touch any given counter.
NonCauserEvent ==
    /\ \E e \in EventKind \ CauserEvents :
         UNCHANGED vars

Next ==
    \/ BumpFromEvent
    \/ NonCauserEvent

Fairness == WF_vars(BumpFromEvent)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety ──────────────────────────────────

\* Core invariant: a positive counter must name a causing event.
CausePresentWhenCounted ==
    counter > 0 => last_cause \in CauserEvents

Safety ==
    /\ TypeOK
    /\ CausePresentWhenCounted

\* ── Bug Model ───────────────────────────────

\* Mutation: a path in the state machine bumps the counter without
\* recording the cause.  In the real code this would be a handler that
\* calls `counter++` but forgets the paired `last_cause := event`
\* assignment — a common drift when new events are added and the
\* incrementing site is updated but the attribution site is not.
BuggyBumpWithoutEvent ==
    /\ counter < MaxCount
    /\ counter' = counter + 1
    /\ UNCHANGED last_cause

SpecBuggy == Init /\ [][Next \/ BuggyBumpWithoutEvent]_vars /\ Fairness

====

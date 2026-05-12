---- MODULE KeeperEventQueue ----
\* Event Layer / Policy Layer separation contract for the keeper
\* heartbeat loop. Models the design in
\* docs/rfc/RFC-0020-keeper-event-queue-layer-separation.md (Draft,
\* 2026-04-30; RFC-0020 cites this spec as #12386), itself derived
\* from RUTHLESS_JUDGMENT.md §1 A5 (the starvation-race walkthrough).
\*
\* Runtime status (2026-05-12, iter 69 Q-2.a):
\*   The Event Layer this spec models is IMPLEMENTED in main, not
\*   aspirational:
\*     - data module: lib/keeper/keeper_event_queue.{ml,mli} — a
\*       persistent FIFO of stimuli (enqueue / dequeue / dedup_by_post_id
\*       / sort_by_urgency / classify / drain_board_window). Its .mli
\*       opens "Models the contract verified in [KeeperEventQueue.tla]".
\*     - enqueue wiring: keeper_keepalive_signal.ml calls
\*       Keeper_registry.enqueue_event before the wakeup flag flips and
\*       comments "RFC-0020 Rule 1 (enqueue is independent of policy)".
\*     - dequeue + override: keeper_heartbeat_loop.ml dequeues once per
\*       turn ("pins the [Conservation] invariant ... in production",
\*       dequeued_total <= enqueued_total) and forces Emit when the
\*       queue is non-empty ("Pinned by KeeperEventQueue.tla
\*       QueueNeverStarvedBySkip invariant").
\*   Remaining honest gap: the consumer-side wiring of
\*   Heartbeat_smart.should_emit (so the Policy Layer reads the queue
\*   before answering Skip) is flagged "follow-up" in keeper_event_queue.mli
\*   and at keeper_heartbeat_loop.ml. The drift this note closes was
\*   audited in iter 68 #14933 (docs/tla-audit/keq-q1-event-queue-spec-
\*   banner-vs-runtime-2026-05-12.md) — the inverse of KOAS M-2.a, where
\*   the runtime owes the spec; here the spec banner had simply not
\*   caught up to the runtime.
\*
\* Runtime entities modelled (see [keeper_event_queue.ml],
\* [keeper_keepalive_signal.ml], [keeper_heartbeat_loop.ml]):
\*
\*   event_queue          : the Event Layer FIFO holding pending
\*                          stimuli (board posts, mentions, operator
\*                          directives) — Keeper_event_queue.t.
\*   smart_decision       : the Policy Layer output of
\*                          Heartbeat_smart.should_emit (Emit/Skip).
\*
\* The boundary critique flagged a starvation race: a stimulus
\* arrives between the Smart Heartbeat decision and the next sleep
\* tick; the policy answers Skip_idle and the stimulus is silently
\* delayed until the next periodic wakeup. This spec models the
\* refactor that adds a real Event Queue and forces the Policy
\* Layer to consult it before committing to Skip.
\*
\* Bug-Model contract (CLAUDE.md software-development.md):
\*   Spec      under KeeperEventQueue.cfg       => TLC: no error.
\*   SpecBuggy under KeeperEventQueue-buggy.cfg => TLC: invariant
\*                                                 violated.
\* Both must hold. The buggy spec models the pre-refactor regression
\* where the heartbeat returns Skip even though the event queue
\* holds an unprocessed stimulus.

EXTENDS Naturals

CONSTANTS
    MaxQueueSize,   \* state-space cap on concurrent enqueued stimuli
    MaxStimuli      \* state-space cap on total Enqueue invocations

ASSUME MaxQueueSizeOK == MaxQueueSize \in Nat /\ MaxQueueSize >= 2
ASSUME MaxStimuliOK   == MaxStimuli   \in Nat /\ MaxStimuli   >= 2

VARIABLES
    queue_size,        \* current depth of the Event Layer queue
    enqueued_total,    \* monotone counter: stimuli observed
    dequeued_total,    \* monotone counter: stimuli consumed by a turn
    smart_decision     \* "tick" | "emit" | "skip"

vars == << queue_size, enqueued_total, dequeued_total, smart_decision >>

\* Class C (NAME COLLISION rename) — DecisionSet identifier in the
\* cross-spec family refers to keeper-turn decision_stage projection
\* (KTC/KCAF/KDP/KCascadeLifecycle/KCompositeLifecycle). KEQ's own
\* decision vocabulary is Heartbeat_smart.should_emit output (see header
\* §"Runtime entities modelled"), unrelated to that family. Renamed to
\* SmartHeartbeatDecisionSet to clarify the boundary.
\* See iter 41 audit docs/tla-audit/cross-spec-3-divergences-classify-2026-05-12.md.
SmartHeartbeatDecisionSet == { "tick", "emit", "skip" }

TypeOK ==
    /\ queue_size      \in 0..MaxQueueSize
    /\ enqueued_total  \in 0..MaxStimuli
    /\ dequeued_total  \in 0..MaxStimuli
    /\ smart_decision  \in SmartHeartbeatDecisionSet

Init ==
    /\ queue_size      = 0
    /\ enqueued_total  = 0
    /\ dequeued_total  = 0
    /\ smart_decision  = "tick"

\* ── Event Layer (Rule 1) ──────────────────────────────────────
\* Enqueue is independent of the Policy Layer: it always succeeds
\* when the queue has capacity. fiber_wakeup is preserved as a
\* hint (not modelled as state) since the queue is now the
\* authoritative data channel.
Enqueue ==
    /\ smart_decision = "tick"
    /\ enqueued_total < MaxStimuli
    /\ queue_size < MaxQueueSize
    /\ queue_size'      = queue_size + 1
    /\ enqueued_total'  = enqueued_total + 1
    /\ UNCHANGED << dequeued_total, smart_decision >>

\* ── Policy Layer (Rules 2-3) ──────────────────────────────────
\* RULE 2: queue non-empty overrides Smart Heartbeat. The tick
\*         shall not settle on Skip while data waits in the Event
\*         Layer.
TickQueueOverride ==
    /\ smart_decision = "tick"
    /\ queue_size > 0
    /\ smart_decision' = "emit"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total >>

\* RULE 3: queue empty => Smart Heartbeat may freely choose Emit
\*         or Skip. We model both branches non-deterministically.
TickHeartbeatSmartEmit ==
    /\ smart_decision = "tick"
    /\ queue_size = 0
    /\ smart_decision' = "emit"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total >>

TickHeartbeatSmartSkip ==
    /\ smart_decision = "tick"
    /\ queue_size = 0
    /\ smart_decision' = "skip"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total >>

\* When the policy decides Emit and the queue has stimuli, the
\* turn dequeues one entry (reactive turn). After the turn the
\* heartbeat returns to "tick" and the next pass re-evaluates
\* both layers.
TurnDequeue ==
    /\ smart_decision = "emit"
    /\ queue_size > 0
    /\ queue_size'     = queue_size - 1
    /\ dequeued_total' = dequeued_total + 1
    /\ smart_decision' = "tick"
    /\ UNCHANGED enqueued_total

\* When the policy decides Emit but the queue is empty, the
\* turn is a scheduled (non-reactive) turn that does not consume
\* from the queue.
TurnScheduled ==
    /\ smart_decision = "emit"
    /\ queue_size = 0
    /\ smart_decision' = "tick"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total >>

\* When the policy decides Skip the heartbeat sleeps without a
\* turn and the next pass re-evaluates the layers.
SleepSkip ==
    /\ smart_decision = "skip"
    /\ smart_decision' = "tick"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total >>

\* Stutter once the run cap is reached and the queue has drained.
Done ==
    /\ enqueued_total = MaxStimuli
    /\ queue_size = 0
    /\ smart_decision = "tick"
    /\ UNCHANGED vars

\* ── Bug action (only in SpecBuggy) ────────────────────────────
\* Models the pre-refactor regression where the Smart Heartbeat
\* returns Skip even though the Event Layer holds unprocessed
\* stimuli. In the OCaml runtime this maps to today's behaviour:
\* fiber_wakeup is observed too late to influence the current
\* tick, the queue does not exist, and Skip_idle silently delays
\* the stimulus until the next periodic wakeup.
TickStarvesQueue ==
    /\ smart_decision = "tick"
    /\ queue_size > 0
    /\ smart_decision' = "skip"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total >>

\* ── Spec wirings ──────────────────────────────────────────────

Next ==
    \/ Enqueue
    \/ TickQueueOverride
    \/ TickHeartbeatSmartEmit
    \/ TickHeartbeatSmartSkip
    \/ TurnDequeue
    \/ TurnScheduled
    \/ SleepSkip
    \/ Done

NextBuggy == Next \/ TickStarvesQueue

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariants ────────────────────────────────────────

\* Conservation: a stimulus is consumed at most once. Trivially
\* true in both Spec and SpecBuggy because the only consumer is
\* TurnDequeue, but the predicate locks it down for future
\* refactors that may add additional dequeue paths.
Conservation ==
    enqueued_total >= dequeued_total

\* Core safety (Rule 2): whenever the Event Layer holds work, the
\* Policy Layer must not commit to Skip. The buggy spec violates
\* this by emitting Skip while queue_size > 0.
QueueNeverStarvedBySkip ==
    ~ (queue_size > 0 /\ smart_decision = "skip")

\* No emit decision sees fewer stimuli than have been enqueued
\* and not yet dequeued — i.e., an Emit must have a corresponding
\* enqueue or a scheduled (queue-empty) reason. This pins the
\* layer split: Emit is either reactive (queue-driven) or
\* scheduled (Smart Heartbeat) but never spurious.
EmitMatchesEvidence ==
    (smart_decision = "emit") =>
        ((queue_size > 0)
         \/ (enqueued_total = dequeued_total))

SafetyInvariant ==
    /\ Conservation
    /\ QueueNeverStarvedBySkip
    /\ EmitMatchesEvidence

====

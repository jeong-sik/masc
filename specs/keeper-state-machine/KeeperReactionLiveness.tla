---- MODULE KeeperReactionLiveness ----
\* KeeperReactionLiveness — TLA+ liveness specification.
\*
\* Models the "leads-to" properties that govern the world-reaction contract:
\* a durable stimulus (board post, verification request, goal check, task
\* transition) must eventually produce either an explicit keeper receipt, a
\* typed terminal reason, or an operator-visible escalation.  It does NOT
\* duplicate the safety invariants in KeeperTurnFSM / KeeperEventQueue /
\* KeeperTaskAcquisition — those remain the authoritative safety SSOT.
\*
\* Runtime status (2026-05-12, iter 59 L-2.a):
\*   This spec is a DESIGN GROUND, not a description of running code.
\*   iter 58 #14898 audit confirmed via rg across lib/keeper/*.ml that
\*   the KRL reaction/receipt FSM (L1-L5 leads-to claims) has NO
\*   matching runtime: verifier_reaction, receipt_issued, task_state
\*   are truly absent everywhere; goal_phase appears as data shape
\*   in lib/goal/ + adjacent modules but not as the per-stimulus FSM
\*   the spec models; board_cursor exists as opaque cursor state in
\*   lib/keeper/keeper_registry.{ml,mli} (get_board_cursor /
\*   set_board_cursor) + lib/keeper/keeper_world_observation.ml, but
\*   without the cursor-ack semantics L5 models (no ack tracking).
\*   Of the five OCaml "mirror" entry points cited below, two exist
\*   as generic plumbing without matching the spec's per-stimulus FSM,
\*   and three do not exist at the cited path (see citation table
\*   below — TBD entries).  Of L1-L5 only L1 has partial coverage
\*   (queue exists, no receipt FSM).
\*
\*   Implementation tracking owner: MASC task
\*   `goal-world-reaction-liveness/task-134`.  Until that work lands,
\*   the invariants below describe the intended contract, not the
\*   running behaviour.  Reader should not assume any L1-L5 claim is
\*   currently enforced in production.
\*
\*   Full implementation gap matrix + L-2.{a..d} fix-PR candidates:
\*   docs/tla-audit/krl-l1-reaction-spec-implementation-gap-2026-05-12.md
\*   (iter 58 #14898).
\*
\* MASC tracking: goal-world-reaction-liveness / task-134
\*
\* Five liveness claims (L1–L5):
\*
\*   L1 BoardEnqueueLeadsToReceipt:
\*     A board/event stimulus queued in the Event Layer must either be
\*     consumed by a keeper turn that issues an explicit receipt, or be
\*     resolved by a typed terminal reason.  A silent drop is not admissible.
\*
\*   L2 VerificationLeadsToReaction:
\*     A verification request submitted for a task must eventually produce
\*     a verifier reaction (approved / rejected) or a timeout-escalation
\*     that makes the stall operator-visible.
\*
\*   L3 GoalVerificationLeadsToResolution:
\*     A goal in the awaiting-verification phase must eventually reach a
\*     terminal phase: done, failed, or operator-visible escalation.
\*
\*   L4 TaskTransitionLeadsToReceipt:
\*     A task in the "transitioning" state must eventually produce an
\*     observable receipt or an operator action-item.
\*
\*   L5 CursorAdvancementRequiresAck:
\*     The board cursor must not advance past an unacknowledged position;
\*     every advance must be tied to a receipt acknowledgement or a
\*     replayable durable state entry.
\*
\* Bug-Model contract (CLAUDE.md software-development.md):
\*   Spec      under KeeperReactionLiveness.cfg       => TLC: no error.
\*   SpecBuggy under KeeperReactionLiveness-buggy.cfg => TLC: property
\*                                                       BoardEnqueueLeadsToReceipt
\*                                                       violated.
\* Both must hold.
\*
\* Mirrors (OCaml runtime entry points; ✓ = present, TBD = not yet
\* implemented per iter 58 #14898 audit):
\*   stimulus / board queue   — ✓ lib/keeper/keeper_event_queue.ml (queue
\*                              plumbing only; no per-stimulus receipt FSM
\*                              as the spec models)
\*   verification FSM         — ✓ lib/keeper/keeper_unified_turn.ml
\*                              (terminal_reason machinery; no
\*                              verification_state / approve / reject
\*                              concepts as the spec models)
\*   goal phase               — TBD: lib/keeper/goal_store.ml not yet
\*                              implemented (MASC task-134 owns this)
\*   task FSM                 — TBD: lib/keeper/keeper_task_dispatch.ml
\*                              not yet implemented (MASC task-134)
\*   board cursor             — PARTIAL: lib/keeper/keeper_registry.{ml,mli}
\*                              (get_board_cursor / set_board_cursor /
\*                              board_cursor_ts) + keeper_world_observation.ml
\*                              track opaque cursor state, but without the
\*                              cursor-ack token L5 models.  Per-stimulus
\*                              board observer (keeper_board_observer.ml)
\*                              not yet implemented (MASC task-134).

EXTENDS TLC

VARIABLES
    stimulus_state,      \* "none"|"queued"|"in_turn"|"receipt_issued"|"terminal_reason"
    verification_state,  \* "idle"|"pending"|"verifier_reaction"|"timeout_escalated"
    goal_phase,          \* "idle"|"awaiting_verification"|"done"|"failed"|"escalated"
    task_state,          \* "idle"|"transitioning"|"receipt_issued"|"action_item"
    cursor_advanced,     \* BOOLEAN: cursor has been advanced to a new position
    cursor_acked         \* BOOLEAN: the current cursor advance has been acknowledged

vars == <<stimulus_state, verification_state, goal_phase, task_state,
          cursor_advanced, cursor_acked>>

StimulusSet     == {"none", "queued", "in_turn", "receipt_issued", "terminal_reason"}
VerificationSet == {"idle", "pending", "verifier_reaction", "timeout_escalated"}
GoalSet         == {"idle", "awaiting_verification", "done", "failed", "escalated"}
TaskSet         == {"idle", "transitioning", "receipt_issued", "action_item"}

TypeOK ==
    /\ stimulus_state     \in StimulusSet
    /\ verification_state \in VerificationSet
    /\ goal_phase         \in GoalSet
    /\ task_state         \in TaskSet
    /\ cursor_advanced    \in BOOLEAN
    /\ cursor_acked       \in BOOLEAN

Init ==
    /\ stimulus_state     = "none"
    /\ verification_state = "idle"
    /\ goal_phase         = "idle"
    /\ task_state         = "idle"
    /\ cursor_advanced    = FALSE
    /\ cursor_acked       = FALSE

\* ── Stimulus lifecycle ──────────────────────────────────────────────────────

\* External producer (board post, operator directive, mention) enqueues a
\* stimulus into the keeper event queue.
EnqueueStimulus ==
    /\ stimulus_state = "none"
    /\ stimulus_state' = "queued"
    /\ UNCHANGED <<verification_state, goal_phase, task_state,
                   cursor_advanced, cursor_acked>>

\* The keeper picks up the queued stimulus and begins a reactive turn.
\* The turn simultaneously latches a goal into awaiting_verification and
\* a task into transitioning (capturing the board/goal/task co-arrival
\* scenario from run_keeper_cycle), and advances the board cursor without
\* yet issuing an acknowledgement.
StartTurn ==
    /\ stimulus_state = "queued"
    /\ stimulus_state' = "in_turn"
    /\ goal_phase'     = IF goal_phase = "idle"
                         THEN "awaiting_verification"
                         ELSE goal_phase
    /\ task_state'     = IF task_state = "idle"
                         THEN "transitioning"
                         ELSE task_state
    /\ cursor_advanced' = TRUE
    /\ cursor_acked'    = FALSE
    /\ UNCHANGED <<verification_state>>

\* Turn completes successfully: the keeper emits an explicit receipt.
\* The in-flight task is settled and the board cursor is acknowledged.
\* Mirrors: keeper_event_queue receipt emission on successful turn.
IssueReceipt ==
    /\ stimulus_state = "in_turn"
    /\ stimulus_state' = "receipt_issued"
    /\ task_state'     = IF task_state = "transitioning"
                         THEN "receipt_issued"
                         ELSE task_state
    /\ cursor_acked'   = TRUE
    /\ UNCHANGED <<verification_state, goal_phase, cursor_advanced>>

\* Turn terminates with a typed terminal reason (tool failure, contract
\* violation, cascade exhaustion, timeout).  The typed reason is an
\* observable outcome — not a silent drop.  Any in-flight task produces
\* an operator action-item; the cursor is acknowledged.
\* Mirrors: keeper_turn_fsm terminal-state emission with typed_terminal_reason.
IssueTerminalReason ==
    /\ stimulus_state = "in_turn"
    /\ stimulus_state' = "terminal_reason"
    /\ task_state'     = IF task_state = "transitioning"
                         THEN "action_item"
                         ELSE task_state
    /\ cursor_acked'   = TRUE
    /\ UNCHANGED <<verification_state, goal_phase, cursor_advanced>>

\* ── Verification lifecycle ───────────────────────────────────────────────────

\* A task enters cross-keeper verification: the requesting keeper submits
\* a verification request to the verification FSM.
\* Mirrors: keeper_unified_turn verification gate entry.
RequestVerification ==
    /\ verification_state = "idle"
    /\ verification_state' = "pending"
    /\ UNCHANGED <<stimulus_state, goal_phase, task_state,
                   cursor_advanced, cursor_acked>>

\* A distinct verifier keeper approves or rejects; the request resolves
\* and any associated goal transitions to done.
\* Mirrors: keeper_task_dispatch ApproveVerification / RejectVerification.
VerifierReaction ==
    /\ verification_state = "pending"
    /\ verification_state' = "verifier_reaction"
    /\ goal_phase'         = IF goal_phase = "awaiting_verification"
                             THEN "done"
                             ELSE goal_phase
    /\ UNCHANGED <<stimulus_state, task_state, cursor_advanced, cursor_acked>>

\* No verifier responds within the deadline; the stall becomes
\* operator-visible via timeout escalation.
\* Mirrors: verification_timeout_escalation event in keeper_lifecycle_events.
TimeoutEscalation ==
    /\ verification_state = "pending"
    /\ verification_state' = "timeout_escalated"
    /\ goal_phase'         = IF goal_phase = "awaiting_verification"
                             THEN "escalated"
                             ELSE goal_phase
    /\ UNCHANGED <<stimulus_state, task_state, cursor_advanced, cursor_acked>>

\* ── Goal lifecycle ──────────────────────────────────────────────────────────

\* Independent rejection path: operator or verifier rejects the goal
\* directly without a verification-request round-trip.  Reaches
\* goal_phase = "failed", satisfying L3 on its own.
\* Mirrors: masc_goal_transition action=reject in goal_tools.ml.
GoalFailed ==
    /\ goal_phase = "awaiting_verification"
    /\ goal_phase' = "failed"
    /\ UNCHANGED <<stimulus_state, verification_state, task_state,
                   cursor_advanced, cursor_acked>>

\* ── Spec wiring ──────────────────────────────────────────────────────────────

Next ==
    \/ EnqueueStimulus
    \/ StartTurn
    \/ IssueReceipt
    \/ IssueTerminalReason
    \/ RequestVerification
    \/ VerifierReaction
    \/ TimeoutEscalation
    \/ GoalFailed

\* Fairness: all progress-driving actions are weakly fair.
\*
\* WF_vars(StartTurn) is required for L1 (BoardEnqueueLeadsToReceipt):
\* without it, the model is allowed to stutter indefinitely in
\* stimulus_state = "queued" without ever starting a turn, making the
\* leads-to property unprovable on the clean model.  The WF obligation
\* encodes the runtime assumption that a queued stimulus is always
\* eventually picked up by the keeper keepalive loop.
\*
\* WF_vars(RequestVerification) is required for L2
\* (VerificationLeadsToReaction): a task whose contract requires
\* cross-keeper verification must eventually submit that request;
\* without the WF obligation the model can stall indefinitely with
\* verification_state = "idle" while a goal waits in
\* "awaiting_verification", making both L2 and L3 unprovable.
Fairness ==
    /\ WF_vars(StartTurn)
    /\ WF_vars(IssueReceipt)
    /\ WF_vars(IssueTerminalReason)
    /\ WF_vars(RequestVerification)
    /\ WF_vars(VerifierReaction)
    /\ WF_vars(TimeoutEscalation)
    /\ WF_vars(GoalFailed)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Bug action ──────────────────────────────────────────────────────────────

\* BugSilentStimulusDrop: the keeper starts a reactive turn for the queued
\* stimulus (stimulus_state = "in_turn") but terminates without issuing
\* either a receipt or a typed terminal reason.  The stimulus is silently
\* discarded, task_state returns to "idle", and cursor_advanced is reset
\* without ever setting cursor_acked.
\*
\* This violates BoardEnqueueLeadsToReceipt (L1): the stimulus_state
\* returns to "none" without passing through "receipt_issued" or
\* "terminal_reason".
\*
\* In the OCaml runtime this corresponds to a run_keeper_cycle execution
\* that returns Ok meta on a world_observation carrying an unresolved
\* board event without emitting an event-queue receipt or recording a
\* typed failure reason.
BugSilentStimulusDrop ==
    /\ stimulus_state = "in_turn"
    /\ stimulus_state'  = "none"
    /\ task_state'      = "idle"
    /\ cursor_advanced' = FALSE
    /\ cursor_acked'    = FALSE
    /\ UNCHANGED <<verification_state, goal_phase>>

NextBuggy == Next \/ BugSilentStimulusDrop

\* FairnessBuggy: mirrors the clean Fairness obligations for every
\* progress-driving action, with two differences that introduce the bug:
\*
\*   1. WF_vars(BugSilentStimulusDrop) is added: the silent-drop action
\*      fires reliably whenever the keeper is in_turn.
\*
\*   2. WF_vars(IssueReceipt) and WF_vars(IssueTerminalReason) are
\*      omitted: a receipt or terminal reason is no longer guaranteed.
\*      In a WF-fair execution, BugSilentStimulusDrop will fire whenever
\*      it is continuously enabled (stimulus_state = "in_turn"), so a
\*      receipt or terminal reason may not be reached before the drop
\*      occurs -- demonstrating the silent-drop failure mode.
\*
\* WF_vars(StartTurn) and WF_vars(RequestVerification) are kept so the
\* counterexample exercises the intended none -> queued -> in_turn -> none
\* cycle rather than a degenerate stutter in stimulus_state = "queued".
FairnessBuggy ==
    /\ WF_vars(StartTurn)
    /\ WF_vars(BugSilentStimulusDrop)
    /\ WF_vars(RequestVerification)
    /\ WF_vars(VerifierReaction)
    /\ WF_vars(TimeoutEscalation)
    /\ WF_vars(GoalFailed)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

\* ── Safety invariants ────────────────────────────────────────────────────────

\* An advanced cursor must have been acknowledged, unless the keeper is
\* currently processing the turn that advanced it (in_turn).  A completed
\* turn (receipt or terminal_reason) must also ack the cursor.
CursorInTurnOrAcked ==
    cursor_advanced =>
        (cursor_acked \/ stimulus_state = "in_turn")

\* Structural coupling: a task in the transitioning state was launched
\* by StartTurn, which simultaneously set stimulus_state to "in_turn".
\* Both are always cleared together by IssueReceipt or IssueTerminalReason.
TaskTransitioningImpliesTurnActive ==
    task_state = "transitioning" => stimulus_state = "in_turn"

Safety ==
    /\ TypeOK
    /\ CursorInTurnOrAcked
    /\ TaskTransitioningImpliesTurnActive

\* ── Liveness properties (leads-to) ──────────────────────────────────────────

\* L1: A board/event stimulus queued in the Event Layer must eventually
\* produce a keeper turn receipt or a typed terminal reason.
BoardEnqueueLeadsToReceipt ==
    (stimulus_state = "queued") ~>
        (stimulus_state \in {"receipt_issued", "terminal_reason"})

\* L2: A pending verification request must eventually produce a verifier
\* reaction or a timeout escalation.
VerificationLeadsToReaction ==
    (verification_state = "pending") ~>
        (verification_state \in {"verifier_reaction", "timeout_escalated"})

\* L3: A goal in awaiting_verification must eventually reach a terminal
\* resolution: done, failed, or operator-visible escalation.
GoalVerificationLeadsToResolution ==
    (goal_phase = "awaiting_verification") ~>
        (goal_phase \in {"done", "failed", "escalated"})

\* L4: A task in the transitioning state must eventually produce an
\* observable receipt or an operator action-item.
TaskTransitionLeadsToReceipt ==
    (task_state = "transitioning") ~>
        (task_state \in {"receipt_issued", "action_item"})

\* L5: A cursor advance without acknowledgement must eventually be
\* acknowledged, ensuring cursor advancement is tied to a reaction
\* receipt or replayable durable state.
CursorAdvancementRequiresAck ==
    (cursor_advanced /\ ~cursor_acked) ~> cursor_acked

====

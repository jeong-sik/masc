---- MODULE KeeperHeartbeat ----
\* Heartbeat loop control flow for [lib/keeper/keeper_keepalive.ml].
\*
\* Function names are stable identifiers; lines drift across edits.
\* Verified against main as of 2026-04-28 (sibling refresh to #11641,
\* #11645; see Cycle 27 PR #11596 for the OCaml-side anchor).
\*
\* Runtime entities modelled (see [run_heartbeat_loop] at line 1828,
\* and [Atomic.set entry.fiber_wakeup true] at lines 2143 and 2644):
\*
\*   wakeup_signaled  : bool Atomic.t — set by external supervisor /
\*                      operator code when a keeper should service a
\*                      pending event.  Cleared when the heartbeat tick
\*                      starts a turn.
\*   turn_state       : "idle" | "running" — abstract over the rich
\*                      OCaml turn FSM (see [keeper_turn_fsm.mli]); for
\*                      this spec we only need to know whether a turn
\*                      is in flight.
\*
\* The user-flagged failure mode that motivates this spec
\* (Cycle 7 / Tier B1 of the Kimi keeper FSM review plan) is the
\* "missed wakeup": a tick observes [wakeup_signaled = TRUE], clears
\* it, but does not transition [turn_state] to "running".  The signal
\* is consumed without being served.  In production this manifests as
\* a keeper that appears alive (heartbeat fiber still running) but
\* never wakes up to do work.
\*
\* Bug-Model contract (CLAUDE.md software-development.md):
\*   Spec      under KeeperHeartbeat.cfg       => TLC: no error.
\*   SpecBuggy under KeeperHeartbeat-buggy.cfg => TLC: invariant
\*                                                 violated.
\* Both must hold.

EXTENDS Naturals

CONSTANTS MaxUnserved   \* invariant cap for unserved_signals counter

ASSUME MaxUnservedNat == MaxUnserved \in Nat /\ MaxUnserved >= 1

VARIABLES
    wakeup_signaled,
    turn_state,
    unserved_signals    \* edge-triggered counter: incremented on every
                        \* FALSE -> TRUE transition of wakeup_signaled,
                        \* decremented when a turn actually starts.

vars == << wakeup_signaled, turn_state, unserved_signals >>

TypeOK ==
    /\ wakeup_signaled  \in BOOLEAN
    /\ turn_state       \in {"idle", "running"}
    /\ unserved_signals \in 0..MaxUnserved

Init ==
    /\ wakeup_signaled  = FALSE
    /\ turn_state       = "idle"
    /\ unserved_signals = 0

\* ── Honest actions ─────────────────────────────────────────────

\* External code (supervisor, operator, gRPC heartbeat) sets the
\* wakeup atomic.  Idempotent: setting TRUE when already TRUE does
\* not stack, but a fresh FALSE -> TRUE transition increments the
\* unserved counter so we can prove the loop services every edge.
WakeupSignal ==
    /\ unserved_signals < MaxUnserved
    /\ wakeup_signaled' = TRUE
    /\ unserved_signals' = IF wakeup_signaled = FALSE
                           THEN unserved_signals + 1
                           ELSE unserved_signals
    /\ UNCHANGED turn_state

\* The heartbeat loop ticks: it observes a pending wakeup while idle
\* and starts a turn.  In OCaml this is the path where
\* [Atomic.exchange wakeup false] returns true and the loop calls
\* [run_keeper_cycle] (or the equivalent dispatch).
HeartbeatTick ==
    /\ wakeup_signaled = TRUE
    /\ turn_state = "idle"
    /\ wakeup_signaled' = FALSE
    /\ turn_state' = "running"
    /\ unserved_signals' = unserved_signals - 1

\* The turn finishes; keeper returns to idle, ready for the next
\* heartbeat poll.  The wakeup atomic is unaffected here.
TurnComplete ==
    /\ turn_state = "running"
    /\ turn_state' = "idle"
    /\ UNCHANGED << wakeup_signaled, unserved_signals >>

\* Stutter step so TLC does not flag deadlock in quiescent states.
Done ==
    /\ wakeup_signaled = FALSE
    /\ turn_state = "idle"
    /\ UNCHANGED vars

\* ── Bug action (only in SpecBuggy) ─────────────────────────────

\* Models the "missed wakeup": the heartbeat tick observes the
\* signal, clears it, but does NOT start a turn.  In the OCaml
\* runtime this is what happens if (for example) the polling logic
\* reads-then-clears the atomic and then takes an early-return
\* before the dispatch path.
MissedWakeup ==
    /\ wakeup_signaled = TRUE
    /\ turn_state = "idle"
    /\ wakeup_signaled' = FALSE
    /\ UNCHANGED turn_state           \* turn does NOT start
    /\ UNCHANGED unserved_signals      \* counter NOT decremented

\* ── Spec wirings ───────────────────────────────────────────────

Next      == WakeupSignal \/ HeartbeatTick \/ TurnComplete \/ Done
NextBuggy == Next \/ MissedWakeup

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariants ─────────────────────────────────────────

\* Core safety: the unserved-signal counter is bounded.  Under the
\* clean Next, every WakeupSignal edge is matched by a later
\* HeartbeatTick that decrements it, so the counter cannot exceed
\* the bound.  Under SpecBuggy, MissedWakeup consumes the signal
\* without decrementing — a follow-up WakeupSignal then increments
\* past the bound, violating this invariant.
NoMissedSignals == unserved_signals <= 1

\* Sanity: when the wakeup atomic is FALSE and the keeper is idle,
\* there cannot be any unserved signal in flight.  This catches a
\* subtler form of the bug where MissedWakeup leaves
\* unserved_signals > 0 even after the visible state suggests
\* nothing is pending.
QuiescentImpliesServed ==
    (wakeup_signaled = FALSE /\ turn_state = "idle")
        => unserved_signals = 0

SafetyInvariant ==
    /\ NoMissedSignals
    /\ QuiescentImpliesServed

====

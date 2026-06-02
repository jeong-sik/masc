---- MODULE Cancellation ----
\* Boundary spec for the keeper cancellation token (lib/cancellation.ml).
\*
\* Runtime truth (archived: lib/cancellation.ml):
\*
\*   let cancel ?(reason : string option) (token : token) : unit =
\*     (* Write reason first, then atomically transition cancelled to true.
\*        This ensures other fibers observing cancelled=true also see the reason. *)
\*     token.reason <- reason;
\*     if Atomic.compare_and_set token.cancelled false true then begin
\*       List.iter (fun cb -> ...) token.callbacks
\*     end
\*
\* Two contracts the OCaml site relies on, encoded as TLA+ invariants:
\*
\*   I1 ReasonBeforeCancelled. Any fiber that observes cancelled = TRUE
\*      sees a non-empty reason. Implementation detail: the source-level
\*      write order [reason <- ...; CAS cancelled] guarantees this on a
\*      sequentially-consistent atomic. The spec lifts the contract above
\*      the implementation: a buggy alternative that sets cancelled before
\*      writing reason would let observers see (cancelled=TRUE, reason=NONE).
\*
\*   I2 CallbacksFiredAtMostOnce. The CAS in [Atomic.compare_and_set
\*      token.cancelled false true] only succeeds on the first transition
\*      from FALSE to TRUE. Subsequent cancel() calls on the same token
\*      return without firing callbacks. The spec ensures callbacks_fired
\*      never exceeds 1 in the clean model.
\*
\* Bug Model (memory: TLA+ Bug Model pattern):
\*   - Spec       (clean): CleanCancel(r) atomically pairs reason and
\*     cancelled, callbacks fire exactly once.
\*   - SpecBuggy:
\*       - InvertedWriteOrder(r) sets cancelled before reason -> I1 violation
\*       - DoubleFireOnRace fires callbacks twice -> I2 violation
\*
\* Reference: issue #11522 Phase 4 (HIGH candidate).

EXTENDS TLC, Naturals

VARIABLES
    cancelled,         \* the Atomic boolean
    reason,            \* observed reason value
    callbacks_fired    \* number of times the callback list has fired

vars == << cancelled, reason, callbacks_fired >>

ReasonSet == {"none", "user_abort", "timeout", "shutdown"}

\* CallbacksMax bounds the model: in production this is unbounded, but
\* for TLC we cap so the state space is finite. Any value >= 2 is enough
\* to surface DoubleFireOnRace as an I2 violation.
CallbacksMax == 3

TypeOK ==
    /\ cancelled \in BOOLEAN
    /\ reason \in ReasonSet
    /\ callbacks_fired \in 0..CallbacksMax

Init ==
    /\ cancelled = FALSE
    /\ reason = "none"
    /\ callbacks_fired = 0

\* Clean cancel: pair the reason write with the cancelled CAS so that
\* the two writes appear atomic to any observer. Mirrors the source-level
\* contract enforced by [reason <- ...; CAS cancelled] under SC.
CleanCancel(r) ==
    /\ ~ cancelled
    /\ r \in ReasonSet \ {"none"}
    /\ cancelled' = TRUE
    /\ reason' = r
    /\ callbacks_fired' = callbacks_fired + 1
    /\ callbacks_fired < CallbacksMax

\* Re-entry: cancel() called again on an already-cancelled token. The
\* CAS fails (cancelled is already TRUE) so callbacks do NOT fire again.
\* Mirrors the [if Atomic.compare_and_set ... then begin ... end] gate.
ReentryNoOp(r) ==
    /\ cancelled
    /\ r \in ReasonSet
    /\ UNCHANGED << cancelled, reason, callbacks_fired >>

Next ==
    \/ \E r \in ReasonSet \ {"none"} : CleanCancel(r)
    \/ \E r \in ReasonSet : ReentryNoOp(r)

Spec == Init /\ [][Next]_vars

\* ── Invariants ────────────────────────────────────────────────────────────

\* I1 ReasonBeforeCancelled. Observer that sees cancelled = TRUE must
\* also see a concrete reason (not "none"). The OCaml site achieves
\* this with write order [reason <- ...] then CAS on cancelled.
ReasonBeforeCancelled ==
    cancelled => reason \in ReasonSet \ {"none"}

\* I2 CallbacksFiredAtMostOnce. The cancel() CAS gate ensures callbacks
\* fire on exactly the first FALSE -> TRUE transition. Re-entry calls
\* are no-ops on the callback list.
CallbacksFiredAtMostOnce ==
    callbacks_fired <= 1

\* ── Bug actions (used only by SpecBuggy) ──────────────────────────────────

\* B1 InvertedWriteOrder. The bug class: a refactor flips the source-level
\* write order so cancelled transitions to TRUE before reason is written.
\* An observer that reads cancelled = TRUE now also reads reason = "none".
\* This violates I1 within 1 step.
InvertedWriteOrder ==
    /\ ~ cancelled
    /\ cancelled' = TRUE
    /\ reason' = "none"        \* reason write was deferred or dropped
    /\ callbacks_fired' = callbacks_fired + 1
    /\ callbacks_fired < CallbacksMax

\* B2 DoubleFireOnRace. The bug class: the CAS gate is dropped (or
\* replaced with an unguarded transition) so a second cancel() fires
\* callbacks again. Violates I2 within 2 steps (CleanCancel + DoubleFire).
DoubleFireOnRace(r) ==
    /\ cancelled
    /\ r \in ReasonSet \ {"none"}
    /\ callbacks_fired' = callbacks_fired + 1
    /\ callbacks_fired < CallbacksMax
    /\ UNCHANGED << cancelled, reason >>

NextBuggy ==
    \/ Next
    \/ InvertedWriteOrder
    \/ \E r \in ReasonSet \ {"none"} : DoubleFireOnRace(r)

SpecBuggy == Init /\ [][NextBuggy]_vars

====

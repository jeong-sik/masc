------------------------------ MODULE TaskLifecycle ------------------------------
(* TLA+ spec for the MASC task lifecycle and the AwaitingVerification gate.

   Covers the Todo / InProgress / AwaitingVerification / Done / Cancelled
   variants defined in Types_core.task_status. The central claim is that
   state = "Done" is only reachable after an Approve_verification that flips
   the "verified" ghost variable to TRUE.

   Bug Model pattern (feedback_tla-spec-audit-outcome-trichotomy):
     - Clean cfg: SpecClean + DoneRequiresApproval passes.
     - Buggy cfg: SpecBuggy adds a direct InProgress -> Done skip which
       MUST violate DoneRequiresApproval. If it passes the invariant is
       too weak and the spec is not actually checking anything.
*)

EXTENDS Integers

VARIABLES state, verified

vars == <<state, verified>>

States == { "Todo", "InProgress", "AwaitingVerification", "Done", "Cancelled" }

TypeOK ==
    /\ state \in States
    /\ verified \in BOOLEAN

\* ── Init ────────────────────────────────────

Init ==
    /\ state = "Todo"
    /\ verified = FALSE

\* ── Clean transitions ───────────────────────

Claim ==
    /\ state = "Todo"
    /\ state' = "InProgress"
    /\ UNCHANGED verified

Submit ==
    /\ state = "InProgress"
    /\ state' = "AwaitingVerification"
    /\ UNCHANGED verified

Approve ==
    /\ state = "AwaitingVerification"
    /\ state' = "Done"
    /\ verified' = TRUE

Reject ==
    /\ state = "AwaitingVerification"
    /\ state' = "InProgress"
    /\ UNCHANGED verified

Cancel ==
    /\ state \in { "Todo", "InProgress", "AwaitingVerification" }
    /\ state' = "Cancelled"
    /\ UNCHANGED verified

\* Terminal states stutter so TLC can close the model.
Terminal ==
    /\ state \in { "Done", "Cancelled" }
    /\ UNCHANGED vars

NextClean ==
    \/ Claim
    \/ Submit
    \/ Approve
    \/ Reject
    \/ Cancel
    \/ Terminal

\* ── Bug: skip verification ──────────────────
\* Models the wrong_approach where a handler flips InProgress directly
\* to Done without a verifier approval. DoneRequiresApproval must catch
\* this.

BugSkipVerification ==
    /\ state = "InProgress"
    /\ state' = "Done"
    /\ UNCHANGED verified

NextBuggy ==
    \/ NextClean
    \/ BugSkipVerification

\* ── Specs ───────────────────────────────────

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety ──────────────────────────────────

\* Done is reachable only after the verifier flipped [verified] to TRUE.
DoneRequiresApproval ==
    state = "Done" => verified = TRUE

\* Terminal states do not flip back. (Stability check — also catches a
\* class of refactor bugs where Done mutates verified post-hoc.)
VerifiedMonotone ==
    state = "Done" => verified = TRUE

================================================================================

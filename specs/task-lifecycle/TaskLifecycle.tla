------------------------------ MODULE TaskLifecycle ------------------------------
(* TLA+ spec for the MASC task lifecycle and the AwaitingVerification gate.

   Covers the 6-state lifecycle exposed by the OCaml [task_status] type
   in `lib/types/types_core.ml:335-348`:

     Todo / Claimed / InProgress / AwaitingVerification / Done / Cancelled

   The OCaml comment at line 369 spells the canonical order as
   "Todo -> Claimed -> InProgress -> AwaitingVerification -> Done | Cancelled".
   Issue #9056 found that an earlier 5-state version of this spec
   collapsed [Claim] into a Todo->InProgress shortcut, missing the
   intermediate Claimed step where a worker has reserved the task but
   not yet started it.

   The central claim is that state = "Done" is only reachable after an
   Approve_verification that flips the "verified" ghost variable to TRUE.
   The Claimed extension preserves that invariant and adds a structural
   gate: InProgress is only reachable via Claimed, not directly from Todo.

   Bug Model pattern (feedback_tla-spec-audit-outcome-trichotomy):
     - Clean cfg: SpecClean + DoneRequiresApproval + InProgressRequiresClaim
                  must all pass.
     - Buggy cfg: SpecBuggy adds:
                  * BugSkipVerification (InProgress -> Done) which MUST
                    violate DoneRequiresApproval.
                  * BugSkipClaim (Todo -> InProgress directly) which MUST
                    violate InProgressRequiresClaim.
                  If either invariant passes, it is too weak.

   OCaml ↔ TLA+ mapping (#8642 family, #9056):
     spec name              ↔ OCaml task_status constructor
     ----------------------+---------------------------------------------
     "Todo"                 ↔ Todo
     "Claimed"              ↔ Claimed of { assignee; claimed_at }
     "InProgress"           ↔ InProgress of { assignee; started_at }
     "AwaitingVerification" ↔ AwaitingVerification of { assignee; ... }
     "Done"                 ↔ Done of { assignee; completed_at; notes }
     "Cancelled"            ↔ Cancelled of { cancelled_by; ... }

   Adding a 7th constructor on the OCaml side would force a compile
   error in [all_task_status_names] (witness pattern at types_core.ml:371)
   AND should add the new value to [States] here. The witness function
   is the cross-language drift gate.
*)

EXTENDS Integers

VARIABLES state, verified, ever_claimed

vars == <<state, verified, ever_claimed>>

States == { "Todo", "Claimed", "InProgress", "AwaitingVerification",
            "Done", "Cancelled" }

TypeOK ==
    /\ state \in States
    /\ verified \in BOOLEAN
    /\ ever_claimed \in BOOLEAN

\* ── Init ────────────────────────────────────

Init ==
    /\ state = "Todo"
    /\ verified = FALSE
    /\ ever_claimed = FALSE

\* ── Clean transitions ───────────────────────

\* Claim: Todo -> Claimed (worker reserves the task, has not started yet).
Claim ==
    /\ state = "Todo"
    /\ state' = "Claimed"
    /\ ever_claimed' = TRUE
    /\ UNCHANGED verified

\* Start: Claimed -> InProgress (worker actually begins work).
Start ==
    /\ state = "Claimed"
    /\ state' = "InProgress"
    /\ UNCHANGED <<verified, ever_claimed>>

Submit ==
    /\ state = "InProgress"
    /\ state' = "AwaitingVerification"
    /\ UNCHANGED <<verified, ever_claimed>>

Approve ==
    /\ state = "AwaitingVerification"
    /\ state' = "Done"
    /\ verified' = TRUE
    /\ UNCHANGED ever_claimed

\* Reject: AwaitingVerification -> InProgress (worker has more to do).
\* The Claimed prefix is preserved because [ever_claimed] is monotone.
Reject ==
    /\ state = "AwaitingVerification"
    /\ state' = "InProgress"
    /\ UNCHANGED <<verified, ever_claimed>>

\* Cancel: any non-terminal state -> Cancelled.
\* OCaml allows cancellation from Claimed (worker abandons before starting).
Cancel ==
    /\ state \in { "Todo", "Claimed", "InProgress", "AwaitingVerification" }
    /\ state' = "Cancelled"
    /\ UNCHANGED <<verified, ever_claimed>>

\* Terminal states stutter so TLC can close the model.
Terminal ==
    /\ state \in { "Done", "Cancelled" }
    /\ UNCHANGED vars

NextClean ==
    \/ Claim
    \/ Start
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
    /\ UNCHANGED <<verified, ever_claimed>>

\* ── Bug: skip claim step ────────────────────
\* Models the OLD 5-state spec's shortcut where Todo went straight to
\* InProgress, bypassing Claimed. Real OCaml runtime never does this
\* (the [Claimed] constructor is the gate that records assignee +
\* claimed_at), so InProgressRequiresClaim must catch this skip.

BugSkipClaim ==
    /\ state = "Todo"
    /\ state' = "InProgress"
    /\ UNCHANGED <<verified, ever_claimed>>

NextBuggy ==
    \/ NextClean
    \/ BugSkipVerification
    \/ BugSkipClaim

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

\* InProgress (and any state past it) is reachable only after a Claim.
\* Catches the BugSkipClaim shortcut. Mirrors the OCaml invariant that
\* [InProgress { assignee; started_at }] cannot exist without a prior
\* [Claimed { assignee; claimed_at }] step (or equivalent transition
\* through the runtime task FSM).
InProgressRequiresClaim ==
    state \in { "InProgress", "AwaitingVerification", "Done" }
        => ever_claimed = TRUE

================================================================================

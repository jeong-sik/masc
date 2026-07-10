------------------------------- MODULE ContinuationGated -------------------------------
\* RFC-0320 G6 safety invariant (TLA+).
\*
\* A continuation (resume) turn — one woken by Hitl_resolved / Connector_attention
\* to continue a conversation on its originating channel — is a continuation of
\* DIALOGUE, not a delegation of privilege. Any NEW gated (privileged) tool the
\* resumed turn invokes must re-enter the approval queue; the resume must not
\* carry a stale approval forward and auto-execute a pending gated call.
\*
\* This spec pins that invariant abstractly (the in-repo runtime re-gating lives
\* in governance_pipeline / runtime_agent_context; the spec covers the safety
\* shape, not the Agent-SDK-external execution semantics).
\*
\* Bug Model pattern (feedback_tla-spec-audit-outcome-trichotomy):
\*   clean cfg  : ContinuationNeverAutoExecutesGated holds
\*   buggy cfg  : AutoExecGatedOnResume violates it
\*   Both must run for the spec to be useful.

EXTENDS TLC

VARIABLES
    \* @type: "idle" | "resumed" | "gated_call" | "done"
    turn,
    \* a gated (privileged) tool call is waiting in the approval queue this turn
    gated_pending,
    \* a gated tool has executed this turn
    gated_executed,
    \* the gated execution was preceded by an approval IN THIS TURN
    gated_approved

vars == <<turn, gated_pending, gated_executed, gated_approved>>

TurnSet == {"idle", "resumed", "gated_call", "done"}

TypeOK ==
    /\ turn \in TurnSet
    /\ gated_pending \in BOOLEAN
    /\ gated_executed \in BOOLEAN
    /\ gated_approved \in BOOLEAN

Init ==
    /\ turn = "idle"
    /\ gated_pending = FALSE
    /\ gated_executed = FALSE
    /\ gated_approved = FALSE

\* A continuation channel resumes the keeper into a dialogue turn.
\* Approvals do NOT carry over from a prior turn — gated_approved resets.
ResumeContinuation ==
    /\ turn = "idle"
    /\ turn' = "resumed"
    /\ gated_pending' = FALSE
    /\ gated_executed' = FALSE
    /\ gated_approved' = FALSE

\* The resumed turn calls a gated tool — it must re-enter the approval queue.
CallGated ==
    /\ turn = "resumed"
    /\ ~gated_pending
    /\ gated_pending' = TRUE
    /\ UNCHANGED <<turn, gated_executed, gated_approved>>

\* Operator approves the gated call → it may execute THIS turn.
ApproveGated ==
    /\ turn = "resumed"
    /\ gated_pending
    /\ gated_pending' = FALSE
    /\ gated_executed' = TRUE
    /\ gated_approved' = TRUE
    /\ UNCHANGED turn

\* Turn ends (no pending gated call left).
FinishTurn ==
    /\ turn = "resumed"
    /\ ~gated_pending
    /\ turn' = "done"
    /\ UNCHANGED <<gated_pending, gated_executed, gated_approved>>

\* Reset to idle, ready for another continuation.
Reset ==
    /\ turn = "done"
    /\ turn' = "idle"
    /\ gated_pending' = FALSE
    /\ gated_executed' = FALSE
    /\ gated_approved' = FALSE

Next ==
    \/ ResumeContinuation
    \/ CallGated
    \/ ApproveGated
    \/ FinishTurn
    \/ Reset

Spec == Init /\ [][Next]_vars

\* ── G6 invariant ───────────────────────────────────────────────────
\* A gated tool executes only when it has been approved in the CURRENT turn.
\* ResumeContinuation resets gated_approved, so a stale approval from a prior
\* turn can never license an execution in the resumed turn.
ContinuationNeverAutoExecutesGated ==
    gated_executed => gated_approved

Safety ==
    /\ TypeOK
    /\ ContinuationNeverAutoExecutesGated

\* ── Buggy variant: a continuation resume auto-executes a previously ──
\*    pending gated call WITHOUT a fresh approval (stale approval carried over).
AutoExecGatedOnResume ==
    /\ turn = "idle"
    /\ gated_pending               \* a gated call was pending from before
    /\ turn' = "resumed"
    /\ gated_executed' = TRUE       \* ... and the resume auto-executes it
    /\ gated_approved' = FALSE      \* ... without a fresh approval
    /\ gated_pending' = FALSE

NextBuggy ==
    \/ AutoExecGatedOnResume
    \/ CallGated
    \/ ApproveGated
    \/ FinishTurn
    \/ Reset

\* A pending gated call must be reachable for the bug to be meaningful, so the
\* buggy init admits a pre-existing pending gated call.
InitBuggy ==
    /\ turn = "idle"
    /\ gated_pending = TRUE
    /\ gated_executed = FALSE
    /\ gated_approved = FALSE

SpecBuggy == InitBuggy /\ [][NextBuggy]_vars

=============================================================================

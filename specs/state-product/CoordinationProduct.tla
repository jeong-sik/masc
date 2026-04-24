--------------------------- MODULE CoordinationProduct ---------------------------
\* Advisory Goal x Task x Board x Reward orthogonal product.
\*
\* Mirrors: lib/coordination_product.ml
\*
\* This model checks cross-axis safety only. Each axis can evolve
\* independently, but terminal goal/reward states require evidence from
\* another axis. The OCaml implementation reports violations in advisory mode
\* instead of blocking writes.
\*
\* Two-config pattern:
\*   CoordinationProduct.cfg       -- clean spec, invariants must hold
\*   CoordinationProduct-buggy.cfg -- buggy spec, invariants MUST be violated

VARIABLES goal, task, board, reward, earned

vars == <<goal, task, board, reward, earned>>

GoalPhases ==
    {"None", "Executing", "AwaitingVerification", "AwaitingApproval",
     "Blocked", "Paused", "Completed", "Dropped"}

TaskPhases ==
    {"NoTask", "Todo", "Claimed", "InProgress", "AwaitingVerification",
     "Done", "Cancelled", "Mixed"}

BoardPhases ==
    {"Quiet", "SignalPending", "SignalAcknowledged", "SignalExpired",
     "Degraded"}

RewardPhases ==
    {"Disabled", "Neutral", "CreditPending", "Rewarded", "Spent",
     "Penalized"}

OpenTasks == {"Todo", "Claimed", "InProgress", "AwaitingVerification", "Mixed"}
TerminalGoals == {"Completed", "Dropped"}
EvidenceTasks == {"Done"}
EarnedRewards == {"Rewarded", "Spent"}

TypeOK ==
    /\ goal \in GoalPhases
    /\ task \in TaskPhases
    /\ board \in BoardPhases
    /\ reward \in RewardPhases
    /\ earned \in BOOLEAN

Init ==
    /\ goal = "Executing"
    /\ task = "NoTask"
    /\ board = "Quiet"
    /\ reward = "Disabled"
    /\ earned = FALSE

\* ── Clean axis transitions ─────────────────────────────────────

TaskCreate ==
    /\ task = "NoTask"
    /\ goal \notin TerminalGoals
    /\ task' = "Todo"
    /\ UNCHANGED <<goal, board, reward, earned>>

TaskClaim ==
    /\ task = "Todo"
    /\ goal \notin TerminalGoals
    /\ task' = "Claimed"
    /\ UNCHANGED <<goal, board, reward, earned>>

TaskStart ==
    /\ task = "Claimed"
    /\ goal \notin TerminalGoals
    /\ task' = "InProgress"
    /\ UNCHANGED <<goal, board, reward, earned>>

TaskSubmit ==
    /\ task = "InProgress"
    /\ goal \notin TerminalGoals
    /\ task' = "AwaitingVerification"
    /\ goal' = "AwaitingVerification"
    /\ UNCHANGED <<board, reward, earned>>

TaskApprove ==
    /\ task = "AwaitingVerification"
    /\ task' = "Done"
    /\ UNCHANGED <<goal, board, reward, earned>>

TaskCancel ==
    /\ task \in OpenTasks
    /\ goal \notin TerminalGoals
    /\ task' = "Cancelled"
    /\ UNCHANGED <<goal, board, reward, earned>>

BoardSignal ==
    /\ board = "Quiet"
    /\ goal \notin TerminalGoals
    /\ task \in OpenTasks
    /\ board' = "SignalPending"
    /\ UNCHANGED <<goal, task, reward, earned>>

BoardAcknowledge ==
    /\ board = "SignalPending"
    /\ task \notin OpenTasks
    /\ board' = "SignalAcknowledged"
    /\ UNCHANGED <<goal, task, reward, earned>>

BoardExpire ==
    /\ board = "SignalPending"
    /\ board' = "SignalExpired"
    /\ UNCHANGED <<goal, task, reward, earned>>

GoalComplete ==
    /\ goal \in {"Executing", "AwaitingVerification", "AwaitingApproval"}
    /\ task = "Done"
    /\ board # "SignalPending"
    /\ goal' = "Completed"
    /\ UNCHANGED <<task, board, reward, earned>>

GoalDrop ==
    /\ goal \notin TerminalGoals
    /\ task \notin OpenTasks
    /\ board # "SignalPending"
    /\ reward # "CreditPending"
    /\ goal' = "Dropped"
    /\ UNCHANGED <<task, board, reward, earned>>

RewardEnable ==
    /\ reward = "Disabled"
    /\ reward' = "Neutral"
    /\ UNCHANGED <<goal, task, board, earned>>

RewardPending ==
    /\ reward = "Neutral"
    /\ task = "Done"
    /\ reward' = "CreditPending"
    /\ UNCHANGED <<goal, task, board, earned>>

RewardEarn ==
    /\ reward \in {"Neutral", "CreditPending"}
    /\ (task = "Done" \/ board = "SignalAcknowledged")
    /\ reward' = "Rewarded"
    /\ earned' = TRUE
    /\ UNCHANGED <<goal, task, board>>

RewardSpend ==
    /\ reward = "Rewarded"
    /\ earned = TRUE
    /\ reward' = "Spent"
    /\ UNCHANGED <<goal, task, board, earned>>

Terminal ==
    /\ goal \in TerminalGoals
    /\ UNCHANGED vars

NextClean ==
    \/ TaskCreate
    \/ TaskClaim
    \/ TaskStart
    \/ TaskSubmit
    \/ TaskApprove
    \/ TaskCancel
    \/ BoardSignal
    \/ BoardAcknowledge
    \/ BoardExpire
    \/ GoalComplete
    \/ GoalDrop
    \/ RewardEnable
    \/ RewardPending
    \/ RewardEarn
    \/ RewardSpend
    \/ Terminal

\* ── Bug transitions that must violate safety ───────────────────

BugCompleteWithOpenTask ==
    /\ task = "InProgress"
    /\ goal' = "Completed"
    /\ UNCHANGED <<task, board, reward, earned>>

BugRewardWithoutEvidence ==
    /\ task \notin EvidenceTasks
    /\ board # "SignalAcknowledged"
    /\ earned = FALSE
    /\ reward' = "Rewarded"
    /\ UNCHANGED <<goal, task, board, earned>>

BugBoardPendingTerminal ==
    /\ task = "Done"
    /\ board' = "SignalPending"
    /\ goal' = "Completed"
    /\ UNCHANGED <<task, reward, earned>>

NextBuggy ==
    \/ NextClean
    \/ BugCompleteWithOpenTask
    \/ BugRewardWithoutEvidence
    \/ BugBoardPendingTerminal

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Cross-axis safety ──────────────────────────────────────────

TerminalGoalNoOpenTask ==
    goal \in TerminalGoals => task \notin OpenTasks

RewardNeedsEvidence ==
    reward \in EarnedRewards =>
        task \in EvidenceTasks \/ board = "SignalAcknowledged" \/ earned

TerminalGoalNoPendingBoard ==
    goal \in TerminalGoals => board # "SignalPending"

SafetyInvariant ==
    /\ TypeOK
    /\ TerminalGoalNoOpenTask
    /\ RewardNeedsEvidence
    /\ TerminalGoalNoPendingBoard

================================================================================

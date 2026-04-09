\* Mirror of ../keeper-state-machine/KeeperWorkPipeline.tla for TLC runs that
\* resolve INSTANCE imports relative to bug-models/.
---- MODULE KeeperWorkPipeline ----
\* Keeper Autonomous Work Pipeline — TLA+ Formal Specification
\*
\* Models the deterministic core of a keeper's autonomous task execution:
\* workspace lifecycle, file operations, commit safety, PR creation, review cycles.
\*
\* Complementary to KeeperStateMachine (lifecycle) and KeeperTurnCycle (turns).
\* This spec models what happens WITHIN a Running phase when a keeper executes
\* an autonomous coding task.
\*
\* Verifies properties that unit tests cannot:
\*   - Path traversal safety (writes always inside workspace boundary)
\*   - Identity consistency (all commits use same keeper identity)
\*   - No force push (force push never succeeds)
\*   - Review before submit (at least one review before PR creation)
\*   - No orphan workspaces (initialized workspaces always cleaned up)
\*
\* Mirrors: lib/keeper/keeper_exec_github.ml, lib/tool_code_write.ml

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxBudget,         \* Total operation budget (bounds state space)
    MaxReviewRounds    \* Maximum review-address cycles before failure

VARIABLES
    pipeline_phase,
    workspace_init,
    workspace_cleaned,
    workspace_preserved,
    keeper_identity,
    commit_identity,
    review_count,
    submit_count,
    force_push_attempted,
    budget_remaining,
    address_rounds,
    file_write_path,
    auth_valid

vars == <<pipeline_phase, workspace_init, workspace_cleaned,
          workspace_preserved, keeper_identity, commit_identity,
          review_count, submit_count, force_push_attempted,
          budget_remaining, address_rounds, file_write_path,
          auth_valid>>

PipelinePhases == {"Idle", "Preflight", "WorkspaceInit", "Coding",
                   "Testing", "Reviewing", "Submitting",
                   "AwaitingReview", "Addressing", "Completed", "Failed"}

TerminalPhases == {"Completed", "Failed"}

\* ── Type Invariant ──────────────────────────────────────────

TypeOK ==
    /\ pipeline_phase \in PipelinePhases
    /\ workspace_init \in BOOLEAN
    /\ workspace_cleaned \in BOOLEAN
    /\ workspace_preserved \in BOOLEAN
    /\ keeper_identity \in {1}           \* Fixed identity token
    /\ commit_identity \in 0..1          \* 0 = not yet committed
    /\ review_count \in 0..MaxReviewRounds + 1
    /\ submit_count \in 0..MaxBudget
    /\ force_push_attempted \in BOOLEAN
    /\ budget_remaining \in 0..MaxBudget
    /\ address_rounds \in 0..MaxReviewRounds
    /\ file_write_path \in {"none", "inside", "outside"}
    /\ auth_valid \in BOOLEAN

\* ── Initial State ───────────────────────────────────────────

Init ==
    /\ pipeline_phase = "Idle"
    /\ workspace_init = FALSE
    /\ workspace_cleaned = FALSE
    /\ workspace_preserved = FALSE
    /\ keeper_identity = 1
    /\ commit_identity = 0
    /\ review_count = 0
    /\ submit_count = 0
    /\ force_push_attempted = FALSE
    /\ budget_remaining = MaxBudget
    /\ address_rounds = 0
    /\ file_write_path = "none"
    /\ auth_valid = FALSE

\* ── Helper ──────────────────────────────────────────────────

HasBudget == budget_remaining > 0
NotTerminal == pipeline_phase \notin TerminalPhases
ConsumeBudget == budget_remaining' = budget_remaining - 1

\* ── Actions ─────────────────────────────────────────────────

StartPreflight ==
    /\ pipeline_phase = "Idle"
    /\ HasBudget
    /\ pipeline_phase' = "Preflight"
    /\ auth_valid' = TRUE    \* Nondeterministic in bug model
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path>>

PreflightFail ==
    /\ pipeline_phase = "Preflight"
    /\ ~auth_valid
    /\ pipeline_phase' = "Failed"
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, budget_remaining,
                   address_rounds, file_write_path, auth_valid>>

InitWorkspace ==
    /\ pipeline_phase = "Preflight"
    /\ auth_valid
    /\ HasBudget
    /\ pipeline_phase' = "WorkspaceInit"
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

WorkspaceReady ==
    /\ pipeline_phase = "WorkspaceInit"
    /\ HasBudget
    /\ pipeline_phase' = "Coding"
    /\ workspace_init' = TRUE
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

WorkspaceInitFail ==
    /\ pipeline_phase = "WorkspaceInit"
    /\ pipeline_phase' = "Failed"
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, budget_remaining,
                   address_rounds, file_write_path, auth_valid>>

\* Safe WriteFile: always writes inside workspace boundary
WriteFile ==
    /\ pipeline_phase = "Coding"
    /\ workspace_init
    /\ HasBudget
    /\ file_write_path' = "inside"    \* Bug model overrides this
    /\ ConsumeBudget
    /\ UNCHANGED <<pipeline_phase, workspace_init, workspace_cleaned,
                   workspace_preserved, keeper_identity, commit_identity,
                   review_count, submit_count, force_push_attempted,
                   address_rounds, auth_valid>>

StartTesting ==
    /\ pipeline_phase = "Coding"
    /\ workspace_init
    /\ HasBudget
    /\ pipeline_phase' = "Testing"
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

TestSucceeds ==
    /\ pipeline_phase = "Testing"
    /\ HasBudget
    /\ pipeline_phase' = "Reviewing"
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

TestFails ==
    /\ pipeline_phase = "Testing"
    /\ HasBudget
    /\ pipeline_phase' = "Coding"
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

SelfReview ==
    /\ pipeline_phase = "Reviewing"
    /\ HasBudget
    /\ review_count' = review_count + 1
    /\ ConsumeBudget
    /\ UNCHANGED <<pipeline_phase, workspace_init, workspace_cleaned,
                   workspace_preserved, keeper_identity, commit_identity,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

ReviewComplete ==
    /\ pipeline_phase = "Reviewing"
    /\ review_count > 0
    /\ HasBudget
    /\ pipeline_phase' = "Submitting"
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

CommitChanges ==
    /\ pipeline_phase = "Submitting"
    /\ HasBudget
    /\ commit_identity' = keeper_identity   \* Bug model may set differently
    /\ ConsumeBudget
    /\ UNCHANGED <<pipeline_phase, workspace_init, workspace_cleaned,
                   workspace_preserved, keeper_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

PushChanges ==
    /\ pipeline_phase = "Submitting"
    /\ commit_identity > 0
    /\ HasBudget
    /\ ConsumeBudget
    /\ UNCHANGED <<pipeline_phase, workspace_init, workspace_cleaned,
                   workspace_preserved, keeper_identity, commit_identity,
                   review_count, submit_count, force_push_attempted,
                   address_rounds, file_write_path, auth_valid>>

CreatePR ==
    /\ pipeline_phase = "Submitting"
    /\ commit_identity > 0
    /\ HasBudget
    /\ pipeline_phase' = "AwaitingReview"
    /\ submit_count' = submit_count + 1
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

PRApproved ==
    /\ pipeline_phase = "AwaitingReview"
    /\ pipeline_phase' = "Completed"
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, budget_remaining,
                   address_rounds, file_write_path, auth_valid>>

PRChangesRequested ==
    /\ pipeline_phase = "AwaitingReview"
    /\ address_rounds < MaxReviewRounds
    /\ HasBudget
    /\ pipeline_phase' = "Addressing"
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

AddressFeedback ==
    /\ pipeline_phase = "Addressing"
    /\ HasBudget
    /\ pipeline_phase' = "Coding"
    /\ address_rounds' = address_rounds + 1
    /\ ConsumeBudget
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted,
                   file_write_path, auth_valid>>

BudgetExhausted ==
    /\ budget_remaining = 0
    /\ NotTerminal
    /\ pipeline_phase' = "Failed"
    /\ UNCHANGED <<workspace_init, workspace_cleaned, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, budget_remaining,
                   address_rounds, file_write_path, auth_valid>>

CleanupWorkspace ==
    /\ pipeline_phase = "Completed"
    /\ workspace_init
    /\ ~workspace_cleaned
    /\ workspace_cleaned' = TRUE
    /\ UNCHANGED <<pipeline_phase, workspace_init, workspace_preserved,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, budget_remaining,
                   address_rounds, file_write_path, auth_valid>>

PreserveWorkspace ==
    /\ pipeline_phase = "Failed"
    /\ workspace_init
    /\ ~workspace_preserved
    /\ workspace_preserved' = TRUE
    /\ UNCHANGED <<pipeline_phase, workspace_init, workspace_cleaned,
                   keeper_identity, commit_identity, review_count,
                   submit_count, force_push_attempted, budget_remaining,
                   address_rounds, file_write_path, auth_valid>>

\* ── Next ────────────────────────────────────────────────────

Next ==
    \/ StartPreflight
    \/ PreflightFail
    \/ InitWorkspace
    \/ WorkspaceReady
    \/ WorkspaceInitFail
    \/ WriteFile
    \/ StartTesting
    \/ TestSucceeds
    \/ TestFails
    \/ SelfReview
    \/ ReviewComplete
    \/ CommitChanges
    \/ PushChanges
    \/ CreatePR
    \/ PRApproved
    \/ PRChangesRequested
    \/ AddressFeedback
    \/ BudgetExhausted
    \/ CleanupWorkspace
    \/ PreserveWorkspace

\* ── Fairness ────────────────────────────────────────────────

Fairness ==
    /\ WF_vars(WorkspaceReady)
    /\ WF_vars(TestSucceeds)
    /\ WF_vars(ReviewComplete)
    /\ WF_vars(CreatePR)
    /\ WF_vars(PRApproved)
    /\ WF_vars(CleanupWorkspace)
    /\ WF_vars(PreserveWorkspace)
    /\ SF_vars(BudgetExhausted)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety Invariants ───────────────────────────────────────

WorkspaceAlwaysBounded ==
    file_write_path /= "outside"

IdentityConsistent ==
    (commit_identity /= 0) => (commit_identity = keeper_identity)

NoForcePush ==
    ~force_push_attempted

ReviewBeforeSubmit ==
    (submit_count > 0) => (review_count > 0)

WorkspaceCleanOrPreserved ==
    pipeline_phase \in TerminalPhases =>
        (workspace_cleaned \/ workspace_preserved \/ ~workspace_init)

\* ── Liveness Properties ─────────────────────────────────────

EventualCompletion ==
    workspace_init ~> (pipeline_phase \in TerminalPhases)

NoOrphanWorkspace ==
    [](workspace_init => <>(workspace_cleaned \/ workspace_preserved))

====

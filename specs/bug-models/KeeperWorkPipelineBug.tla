---- MODULE KeeperWorkPipelineBug ----
\* Bug Model: Keeper work pipeline path escape and identity mismatch.
\*
\* Models two bug scenarios in the keeper autonomous work pipeline:
\*
\* 1. Path Escape: WriteFile allows file_write_path to be "outside",
\*    simulating a path traversal vulnerability where the keeper writes
\*    outside its workspace boundary.
\*
\* 2. Identity Mismatch: CommitChanges sets commit_identity = 0 instead
\*    of keeper_identity, simulating a bug where commits are made with
\*    wrong or missing identity.
\*
\* Uses INSTANCE to import the clean module and override specific actions.

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxBudget,
    MaxReviewRounds

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

\* Import clean module (all definitions available as Clean!Xxx)
Clean == INSTANCE KeeperWorkPipeline

\* ── Invariants from clean module ────────────────────────────

TypeOK == Clean!TypeOK
WorkspaceAlwaysBounded == Clean!WorkspaceAlwaysBounded
IdentityConsistent == Clean!IdentityConsistent

\* ── Bug Action 1: Path Escape ───────────────────────────────
\* WriteFile allows nondeterministic path: "inside" or "outside".
\* In the clean model, file_write_path is always "inside".

BugWriteFilePathEscape ==
    /\ pipeline_phase = "Coding"
    /\ workspace_init
    /\ Clean!HasBudget
    /\ file_write_path' \in {"inside", "outside"}   \* BUG: nondeterministic
    /\ Clean!ConsumeBudget
    /\ UNCHANGED <<pipeline_phase, workspace_init, workspace_cleaned,
                   workspace_preserved, keeper_identity, commit_identity,
                   review_count, submit_count, force_push_attempted,
                   address_rounds, auth_valid>>

\* ── Bug Action 2: Identity Mismatch ────────────────────────
\* CommitChanges sets commit_identity = 0 (wrong identity) instead of
\* keeper_identity.  Simulates a misconfigured git author.

BugCommitIdentityMismatch ==
    /\ pipeline_phase = "Submitting"
    /\ Clean!HasBudget
    /\ commit_identity' = 0                          \* BUG: wrong identity
    /\ Clean!ConsumeBudget
    /\ UNCHANGED <<pipeline_phase, workspace_init, workspace_cleaned,
                   workspace_preserved, keeper_identity, review_count,
                   submit_count, force_push_attempted, address_rounds,
                   file_write_path, auth_valid>>

\* ── Clean Next (imported) ───────────────────────────────────

Next == Clean!Next

\* ── Buggy Next: Path Escape ─────────────────────────────────
\* Replace WriteFile with BugWriteFilePathEscape in Next.

NextBugPathEscape ==
    \/ Clean!StartPreflight
    \/ Clean!PreflightFail
    \/ Clean!InitWorkspace
    \/ Clean!WorkspaceReady
    \/ Clean!WorkspaceInitFail
    \/ BugWriteFilePathEscape       \* replaces Clean!WriteFile
    \/ Clean!StartTesting
    \/ Clean!TestSucceeds
    \/ Clean!TestFails
    \/ Clean!SelfReview
    \/ Clean!ReviewComplete
    \/ Clean!CommitChanges
    \/ Clean!PushChanges
    \/ Clean!CreatePR
    \/ Clean!PRApproved
    \/ Clean!PRChangesRequested
    \/ Clean!AddressFeedback
    \/ Clean!BudgetExhausted
    \/ Clean!CleanupWorkspace
    \/ Clean!PreserveWorkspace

\* ── Buggy Next: Identity Mismatch ───────────────────────────
\* Replace CommitChanges with BugCommitIdentityMismatch in Next.

NextBugIdentity ==
    \/ Clean!StartPreflight
    \/ Clean!PreflightFail
    \/ Clean!InitWorkspace
    \/ Clean!WorkspaceReady
    \/ Clean!WorkspaceInitFail
    \/ Clean!WriteFile
    \/ Clean!StartTesting
    \/ Clean!TestSucceeds
    \/ Clean!TestFails
    \/ Clean!SelfReview
    \/ Clean!ReviewComplete
    \/ BugCommitIdentityMismatch    \* replaces Clean!CommitChanges
    \/ Clean!PushChanges
    \/ Clean!CreatePR
    \/ Clean!PRApproved
    \/ Clean!PRChangesRequested
    \/ Clean!AddressFeedback
    \/ Clean!BudgetExhausted
    \/ Clean!CleanupWorkspace
    \/ Clean!PreserveWorkspace

\* ── Fairness (reused from clean) ────────────────────────────

Fairness == Clean!Fairness

\* ── Specifications ──────────────────────────────────────────

Spec == Clean!Init /\ [][Next]_vars /\ Fairness

SpecBugPathEscape == Clean!Init /\ [][NextBugPathEscape]_vars /\ Fairness

SpecBugIdentity == Clean!Init /\ [][NextBugIdentity]_vars /\ Fairness

====

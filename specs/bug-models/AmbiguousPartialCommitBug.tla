---- MODULE AmbiguousPartialCommitBug ----
\* Bug model: retry IGNORES committed mutations.
\* This simulates the pre-fix behavior where a transient error after
\* mutating tool calls would still trigger retry, causing duplicate
\* mutations.
\*
\* Expected: TLC finds Safety invariant violation.

EXTENDS Naturals

CONSTANTS
    MaxToolCalls,
    MaxRetries

VARIABLES
    turn_phase,
    tool_calls_made,
    mutating_committed,
    retry_count,
    provider_error,
    retry_performed

vars == <<turn_phase, tool_calls_made, mutating_committed,
          retry_count, provider_error, retry_performed>>

Clean == INSTANCE AmbiguousPartialCommit

TypeOK == Clean!TypeOK

Init == Clean!Init

StartTurn == Clean!StartTurn
ReadOnlyToolCall == Clean!ReadOnlyToolCall
MutatingToolCall == Clean!MutatingToolCall
TurnSuccess == Clean!TurnSuccess

\* BUG: ProviderError retries even when mutations are committed.
\* The clean version goes to "reconcile" when mutating_committed > 0.
\* This buggy version ignores mutations and retries anyway.
BugProviderError ==
    /\ turn_phase = "running"
    /\ provider_error' \in {"timeout", "rate_limit", "internal"}
    /\ IF retry_count < MaxRetries /\ provider_error' \in {"timeout", "rate_limit"}
       THEN \* BUG: retries regardless of committed mutations
            /\ turn_phase' = "running"
            /\ retry_count' = retry_count + 1
            /\ retry_performed' = TRUE
            /\ tool_calls_made' = 0
       ELSE
            /\ turn_phase' = "failed"
            /\ UNCHANGED <<tool_calls_made, retry_count, retry_performed>>
    /\ UNCHANGED mutating_committed

Done == Clean!Done

NextBuggy ==
    \/ StartTurn
    \/ ReadOnlyToolCall
    \/ MutatingToolCall
    \/ TurnSuccess
    \/ BugProviderError
    \/ Done

SpecBuggy == Init /\ [][NextBuggy]_vars

\* Same safety property — should be VIOLATED by the buggy model.
MutationsNeverOrphan == Clean!MutationsNeverOrphan
Safety == MutationsNeverOrphan

====

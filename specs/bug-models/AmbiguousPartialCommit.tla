---- MODULE AmbiguousPartialCommit ----
\* Models the keeper unified turn lifecycle where tool calls can commit
\* side-effects before the LLM response completes. A timeout after
\* committed mutations creates an "ambiguous partial commit" state.
\*
\* Safety property: MutationsNeverOrphan ensures that if mutations are
\* committed, the turn either succeeds or enters the continue gate —
\* never silently retried (which would cause duplicate mutations).
\*
\* Evidence: sangsu keeper, 2026-04-09. Timeout after 573.2s with
\* committed [keeper_board_post, keeper_board_comment, keeper_task_claim].

EXTENDS Naturals

CONSTANTS
    MaxToolCalls,   \* max tool calls per turn (e.g. 10)
    MaxRetries      \* max transient retries (e.g. 2)

VARIABLES
    turn_phase,           \* "init" | "running" | "completed" | "failed" | "continue_gate"
    tool_calls_made,      \* count of tool calls executed
    mutating_committed,   \* count of committed mutating tool calls
    retry_count,          \* current retry attempt
    provider_error,       \* "none" | "timeout" | "rate_limit" | "internal"
    retry_performed       \* whether a retry was actually executed

vars == <<turn_phase, tool_calls_made, mutating_committed,
          retry_count, provider_error, retry_performed>>

TypeOK ==
    /\ turn_phase \in {"init", "running", "completed", "failed", "continue_gate"}
    /\ tool_calls_made \in 0..MaxToolCalls
    /\ mutating_committed \in 0..MaxToolCalls
    /\ retry_count \in 0..MaxRetries
    /\ provider_error \in {"none", "timeout", "rate_limit", "internal"}
    /\ retry_performed \in BOOLEAN

Init ==
    /\ turn_phase = "init"
    /\ tool_calls_made = 0
    /\ mutating_committed = 0
    /\ retry_count = 0
    /\ provider_error = "none"
    /\ retry_performed = FALSE

\* ── Actions ─────────────────────────────────────────────────

StartTurn ==
    /\ turn_phase = "init"
    /\ turn_phase' = "running"
    /\ UNCHANGED <<tool_calls_made, mutating_committed, retry_count,
                    provider_error, retry_performed>>

\* Execute a read-only tool call (no side effect)
ReadOnlyToolCall ==
    /\ turn_phase = "running"
    /\ tool_calls_made < MaxToolCalls
    /\ tool_calls_made' = tool_calls_made + 1
    /\ UNCHANGED <<turn_phase, mutating_committed, retry_count,
                    provider_error, retry_performed>>

\* Execute a mutating tool call (commits side effect)
MutatingToolCall ==
    /\ turn_phase = "running"
    /\ tool_calls_made < MaxToolCalls
    /\ tool_calls_made' = tool_calls_made + 1
    /\ mutating_committed' = mutating_committed + 1
    /\ UNCHANGED <<turn_phase, retry_count, provider_error, retry_performed>>

\* Turn completes successfully
TurnSuccess ==
    /\ turn_phase = "running"
    /\ turn_phase' = "completed"
    /\ provider_error' = "none"
    /\ UNCHANGED <<tool_calls_made, mutating_committed, retry_count,
                    retry_performed>>

\* Provider error occurs (timeout, rate limit, etc.)
ProviderError ==
    /\ turn_phase = "running"
    /\ provider_error' \in {"timeout", "rate_limit", "internal"}
    /\ IF mutating_committed > 0
       THEN \* Ambiguous partial commit — open continue gate, no retry
            /\ turn_phase' = "continue_gate"
            /\ UNCHANGED <<tool_calls_made, retry_count, retry_performed>>
       ELSE IF retry_count < MaxRetries /\ provider_error' \in {"timeout", "rate_limit"}
            THEN \* Transient error, no mutations — safe to retry
                 /\ turn_phase' = "running"
                 /\ retry_count' = retry_count + 1
                 /\ retry_performed' = TRUE
                 /\ tool_calls_made' = 0  \* reset for retry
            ELSE \* Non-retryable or retries exhausted
                 /\ turn_phase' = "failed"
                 /\ UNCHANGED <<tool_calls_made, retry_count, retry_performed>>
    /\ UNCHANGED mutating_committed

\* ── Spec ────────────────────────────────────────────────────

\* Terminal states stutter (prevent TLC deadlock detection)
Done ==
    /\ turn_phase \in {"completed", "failed", "continue_gate"}
    /\ UNCHANGED vars

Next ==
    \/ StartTurn
    \/ ReadOnlyToolCall
    \/ MutatingToolCall
    \/ TurnSuccess
    \/ ProviderError
    \/ Done

Spec == Init /\ [][Next]_vars

\* ── Safety Properties ───────────────────────────────────────

\* Committed mutations + error must go to the continue gate, never to failed.
\* "failed" with committed mutations means mutations were lost without notice.
MutationsNeverOrphan ==
    ~(turn_phase = "failed" /\ mutating_committed > 0)

\* Combined safety invariant.
Safety == MutationsNeverOrphan

\* ── Bug Model: Orphan Mutations ─────────────────────────────
\* Models a regression where ProviderError incorrectly transitions to
\* "failed" when mutations are committed, instead of "continue_gate".
\* SHOULD violate MutationsNeverOrphan.
\*
\* Evidence: sangsu keeper timeout 2026-04-09 — committed mutations
\* followed by failed turn without entering continue_gate.

BugOrphanMutations ==
    /\ turn_phase = "running"
    /\ mutating_committed > 0
    /\ provider_error' = "timeout"
    /\ turn_phase' = "failed"
    /\ UNCHANGED <<tool_calls_made, mutating_committed, retry_count, retry_performed>>

NextBuggy ==
    \/ StartTurn
    \/ ReadOnlyToolCall
    \/ MutatingToolCall
    \/ TurnSuccess
    \/ ProviderError
    \/ BugOrphanMutations
    \/ Done

SpecBuggy == Init /\ [][NextBuggy]_vars

\* Invariant SHOULD be violated under SpecBuggy.
MutationsNeverOrphanMustHold == MutationsNeverOrphan

====

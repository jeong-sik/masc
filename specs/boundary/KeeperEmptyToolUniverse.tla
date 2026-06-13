---- MODULE KeeperEmptyToolUniverse ----
\* Boundary spec for keeper turn empty-tool-universe terminal handling.
\*
\* Phase A F3 of the bloodflow restoration plan introduced the
\* observability counter [masc_empty_tool_universe_observed_total] to
\* surface the volume of the existing [Keeper_tool_surface_empty]
\* blocker branch in keeper_agent_run.ml (line 1235 - entry condition
\* `tool_gate_requested && all_allowed = []`; the actual blocker raise
\* is at line 1256, the Phase A F3 counter at line 1245).
\* Function name [Keeper_tool_surface_empty] is the stable identifier;
\* lines verified against main 2026-04-28. The keeper turn enters a
\* tool-required gate but the visible tool surface is empty.
\*
\* This spec models the bug: a keeper enters a turn with required tools
\* and an empty surface, the blocker fires, but no terminal feedback
\* propagates to the chat-store -- so the LLM never learns why its
\* previous turn was tool-skipped. The clean production model writes
\* LLM-visible feedback at this branch.
\*
\* Pattern (clean Spec + buggy SpecBuggy gated by a separate Bug action)
\* matches KeeperTurnTerminal.tla and KeeperContinueGate.tla.

EXTENDS FiniteSets, TLC

CONSTANTS Keepers
ASSUME Keepers # {}

VARIABLES
    turnState,
    surfaceEmpty,
    feedbackLogged,
    silentSkip

vars == << turnState, surfaceEmpty, feedbackLogged, silentSkip >>

PhaseSet == {"Idle", "ToolSurfaceCheck"}

TypeOK ==
    /\ turnState \in [Keepers -> PhaseSet]
    /\ surfaceEmpty \in [Keepers -> BOOLEAN]
    /\ feedbackLogged \in [Keepers -> BOOLEAN]
    /\ silentSkip \in [Keepers -> BOOLEAN]

Init ==
    /\ turnState = [k \in Keepers |-> "Idle"]
    /\ surfaceEmpty = [k \in Keepers |-> FALSE]
    /\ feedbackLogged = [k \in Keepers |-> FALSE]
    /\ silentSkip = [k \in Keepers |-> FALSE]

\* Idle keeper enters tool-surface assembly when a turn fires.
EnterTurn(k) ==
    /\ turnState[k] = "Idle"
    /\ turnState' = [turnState EXCEPT ![k] = "ToolSurfaceCheck"]
    /\ UNCHANGED <<surfaceEmpty, feedbackLogged, silentSkip>>

\* Surface assembly succeeded, so the normal turn continues.
SurfaceOk(k) ==
    /\ turnState[k] = "ToolSurfaceCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ UNCHANGED <<surfaceEmpty, feedbackLogged, silentSkip>>

\* Surface empty and feedback written to chat-store.
EmptyWithFeedback(k) ==
    /\ turnState[k] = "ToolSurfaceCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ surfaceEmpty' = [surfaceEmpty EXCEPT ![k] = TRUE]
    /\ feedbackLogged' = [feedbackLogged EXCEPT ![k] = TRUE]
    /\ UNCHANGED silentSkip

\* Buggy behavior: surface empty, blocker fires, no chat-store feedback.
EmptySilentSkip(k) ==
    /\ turnState[k] = "ToolSurfaceCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ surfaceEmpty' = [surfaceEmpty EXCEPT ![k] = TRUE]
    /\ silentSkip' = [silentSkip EXCEPT ![k] = TRUE]
    /\ UNCHANGED feedbackLogged

\* Clean Next: production system must not silently skip the empty surface.
Next == \E k \in Keepers :
    \/ EnterTurn(k)
    \/ SurfaceOk(k)
    \/ EmptyWithFeedback(k)

\* Buggy Next: adds the silent-skip action that violates Safety.
NextBuggy == \E k \in Keepers :
    \/ EnterTurn(k)
    \/ SurfaceOk(k)
    \/ EmptyWithFeedback(k)
    \/ EmptySilentSkip(k)

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* Safety: no keeper ever incurs an empty-surface skip without feedback.
NoEmptySurfaceWithoutFeedback ==
    \A k \in Keepers : ~silentSkip[k]

\* Every empty-surface state must have feedback logged.
EmptySurfaceImpliesFeedback ==
    \A k \in Keepers :
        surfaceEmpty[k] => feedbackLogged[k]

Safety ==
    /\ TypeOK
    /\ NoEmptySurfaceWithoutFeedback
    /\ EmptySurfaceImpliesFeedback

====

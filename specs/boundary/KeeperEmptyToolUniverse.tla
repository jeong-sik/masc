---- MODULE KeeperEmptyToolUniverse ----
\* Boundary spec for keeper turn empty-tool-universe terminal handling.
\*
\* Phase A F3 of the bloodflow restoration plan introduced the
\* observability counter [masc_empty_tool_universe_observed_total] to
\* surface the volume of the existing [Keeper_tool_surface_empty]
\* blocker branch in keeper_agent_run.ml (line 1235 — entry condition
\* `tool_gate_requested && all_allowed = []`; the actual blocker raise
\* is at line 1256, the Phase A F3 counter at line 1245).
\* Function name [Keeper_tool_surface_empty] is the stable identifier;
\* lines verified against main 2026-04-28. The keeper turn
\* enters a tool-required gate but the visible tool surface is empty.
\* Pre-fix runtime reality: janitor / verifier keepers exhibit
\* tools_used_count=0 streaks of 14+ turns; a fraction of those land in
\* this branch and the blocker fires silently with no LLM-visible
\* feedback so the next turn repeats the same pattern.
\*
\* This spec models the bug: a keeper enters a turn with required tools
\* and an empty surface, the blocker fires, but no terminal feedback
\* propagates to the chat-store -- so the LLM never learns *why* its
\* previous turn was tool-skipped.  Phase B PR-4 will write
\* LLM-visible feedback at this branch; this spec proves the safety
\* invariant [NoEmptySurfaceWithoutFeedback] catches the missing-feedback
\* bug.
\*
\* Pattern (clean Spec + buggy SpecBuggy gated by a separate Bug action)
\* matches KeeperTurnTerminal.tla (Phase B PR-8) and KeeperContinueGate.tla.

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

\* Surface assembly succeeded -> normal turn continues.
SurfaceOk(k) ==
    /\ turnState[k] = "ToolSurfaceCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ UNCHANGED <<surfaceEmpty, feedbackLogged, silentSkip>>

\* Surface empty AND feedback written to chat-store: Phase B PR-4 target.
\* The LLM sees the terminal_reason_code on its next turn so it can
\* adjust strategy instead of repeating the same tool-required prompt
\* into a void.
EmptyWithFeedback(k) ==
    /\ turnState[k] = "ToolSurfaceCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ surfaceEmpty' = [surfaceEmpty EXCEPT ![k] = TRUE]
    /\ feedbackLogged' = [feedbackLogged EXCEPT ![k] = TRUE]
    /\ UNCHANGED silentSkip

\* THE BUG (pre-Phase B PR-4 keeper_agent_run.ml:~1234): surface empty,
\* blocker fires, NO chat-store feedback.  The LLM has no idea why its
\* turn was skipped, so the next turn re-enters with the same prompt
\* and the cycle continues.  Phase A F3 measures how often this fires
\* (empty_tool_universe_observed counter); this spec models why the
\* missing feedback is the actual bug.
EmptySilentSkip(k) ==
    /\ turnState[k] = "ToolSurfaceCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ surfaceEmpty' = [surfaceEmpty EXCEPT ![k] = TRUE]
    /\ silentSkip' = [silentSkip EXCEPT ![k] = TRUE]
    /\ UNCHANGED feedbackLogged

\* Clean Next: post-Phase-B PR-4 production system.
Next == \E k \in Keepers :
    \/ EnterTurn(k)
    \/ SurfaceOk(k)
    \/ EmptyWithFeedback(k)

\* Buggy Next: pre-Phase-B production system.  Adds the silent-skip
\* action which immediately violates the safety invariant.
NextBuggy == \E k \in Keepers :
    \/ EnterTurn(k)
    \/ SurfaceOk(k)
    \/ EmptyWithFeedback(k)
    \/ EmptySilentSkip(k)

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* Safety: no keeper ever incurs an empty-surface skip without feedback.
\* Clean: trivially holds (action unreachable).
\* Buggy: violated on first EmptySilentSkip firing.
NoEmptySurfaceWithoutFeedback ==
    \A k \in Keepers : ~silentSkip[k]

\* Auxiliary: every empty-surface state must have feedback logged
\* (or be the intermediate transitional state of the silent-skip bug).
\* This invariant is what Phase B PR-4 must ensure: no path to
\* surfaceEmpty[k] = TRUE without feedbackLogged[k] = TRUE.
EmptySurfaceImpliesFeedback ==
    \A k \in Keepers :
        surfaceEmpty[k] => feedbackLogged[k]

Safety ==
    /\ TypeOK
    /\ NoEmptySurfaceWithoutFeedback
    /\ EmptySurfaceImpliesFeedback

====

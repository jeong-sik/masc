---- MODULE KeeperContractViolated ----
\* Boundary spec for keeper turn completion-contract gating.
\*
\* Production reality (24h, 2026-04-26 fleet log measurement):
\*   `Completion contract [require_tool_use] violated: actionable signal
\*    present, model only used passive read-only tools (masc_status x2,
\*    keeper_tasks_list x4)` — 43 events, exceeding even the cascade
\*   exhaustion volume.  See memory entry
\*   feedback_proactive_turn_contract_violation_dominant.md.
\*
\* Plan section 8 footer:
\*   "이 패턴을 EmptyToolUniverse, ContractViolated, StaleKilled 에도
\*    동일하게 적용 (Phase B PR-8)."
\*
\* This spec models the contract-gate boundary.  The keeper sets a
\* turn-level "tool use required" affordance, the LLM emits a turn,
\* and the contract gate validates whether actionable mutating tools
\* were called.  The bug being modeled: the gate detects the violation
\* but the next turn re-enters with the same affordances and prompt
\* because no LLM-visible "you violated the contract last turn"
\* feedback was written to chat-store — same root cause as the
\* empty-tool-universe path (Phase B PR-4).  Phase A telemetry
\* (`required_tool_contract_violation_total`) measures the volume; Phase
\* B PR-4 promotes the gate to a typed terminal state with feedback.
\*
\* Pattern (clean Spec + buggy SpecBuggy gated by a separate Bug action)
\* matches KeeperTurnTerminal.tla, KeeperEmptyToolUniverse.tla, and
\* KeeperContinueGate.tla.

EXTENDS FiniteSets, TLC

CONSTANTS Keepers
ASSUME Keepers # {}

VARIABLES
    turnState,
    contractViolated,
    feedbackLogged,
    silentRepeat

vars == << turnState, contractViolated, feedbackLogged, silentRepeat >>

PhaseSet == {"Idle", "Awaiting", "ContractCheck"}

TypeOK ==
    /\ turnState \in [Keepers -> PhaseSet]
    /\ contractViolated \in [Keepers -> BOOLEAN]
    /\ feedbackLogged \in [Keepers -> BOOLEAN]
    /\ silentRepeat \in [Keepers -> BOOLEAN]

Init ==
    /\ turnState = [k \in Keepers |-> "Idle"]
    /\ contractViolated = [k \in Keepers |-> FALSE]
    /\ feedbackLogged = [k \in Keepers |-> FALSE]
    /\ silentRepeat = [k \in Keepers |-> FALSE]

\* Turn fires with a tool-use-required affordance.
EnterTurn(k) ==
    /\ turnState[k] = "Idle"
    /\ turnState' = [turnState EXCEPT ![k] = "Awaiting"]
    /\ UNCHANGED <<contractViolated, feedbackLogged, silentRepeat>>

\* LLM response received -> contract gate runs.
ResponseReceived(k) ==
    /\ turnState[k] = "Awaiting"
    /\ turnState' = [turnState EXCEPT ![k] = "ContractCheck"]
    /\ UNCHANGED <<contractViolated, feedbackLogged, silentRepeat>>

\* Contract satisfied: actionable mutating tool was called.  Normal
\* completion, reset for the next turn.
ContractSatisfied(k) ==
    /\ turnState[k] = "ContractCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ contractViolated' = [contractViolated EXCEPT ![k] = FALSE]
    /\ UNCHANGED <<feedbackLogged, silentRepeat>>

\* Contract violated AND feedback written to chat-store: Phase B PR-4
\* target.  The LLM sees the contract_violation_reason on the next
\* turn so it can adjust strategy.
ViolatedWithFeedback(k) ==
    /\ turnState[k] = "ContractCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ contractViolated' = [contractViolated EXCEPT ![k] = TRUE]
    /\ feedbackLogged' = [feedbackLogged EXCEPT ![k] = TRUE]
    /\ UNCHANGED silentRepeat

\* THE BUG (pre-Phase B PR-4): contract gate detects the violation but
\* the next turn re-enters with the same affordances + prompt because
\* no LLM-visible feedback was written to the chat-store.  The same
\* passive-read tool sequence repeats the next turn, hence the
\* 43/day "consecutive 14-turn streaks" pattern in production.
ViolatedSilentRepeat(k) ==
    /\ turnState[k] = "ContractCheck"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ contractViolated' = [contractViolated EXCEPT ![k] = TRUE]
    /\ silentRepeat' = [silentRepeat EXCEPT ![k] = TRUE]
    /\ UNCHANGED feedbackLogged

\* Clean Next: post-Phase-B PR-4 production system.
Next == \E k \in Keepers :
    \/ EnterTurn(k)
    \/ ResponseReceived(k)
    \/ ContractSatisfied(k)
    \/ ViolatedWithFeedback(k)

\* Buggy Next: pre-Phase-B production system.
NextBuggy == \E k \in Keepers :
    \/ EnterTurn(k)
    \/ ResponseReceived(k)
    \/ ContractSatisfied(k)
    \/ ViolatedWithFeedback(k)
    \/ ViolatedSilentRepeat(k)

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* Safety: no keeper has ever taken the silent-repeat transition.
\* Clean: trivially holds (action unreachable).
\* Buggy: violated on first ViolatedSilentRepeat firing.
NoSilentContractRepeat ==
    \A k \in Keepers : ~silentRepeat[k]

\* Auxiliary: every contract violation must be paired with feedback.
\* Phase B PR-4 must enforce that no path leaves
\* contractViolated[k] = TRUE without feedbackLogged[k] = TRUE.
ViolatedImpliesFeedback ==
    \A k \in Keepers :
        contractViolated[k] => feedbackLogged[k]

Safety ==
    /\ TypeOK
    /\ NoSilentContractRepeat
    /\ ViolatedImpliesFeedback

====

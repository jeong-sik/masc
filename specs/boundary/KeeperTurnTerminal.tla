---- MODULE KeeperTurnTerminal ----
\* Boundary spec for keeper auth-resolve terminal-state surfacing.
\*
\* Phase A F2 of the bloodflow restoration plan introduced a measurement
\* surface (masc_auth_strict_would_reject_total) for the silent alias-keep
\* fall-through in mcp_server_eio_execute.  Pre-fix runtime reality
\* (24h, 2026-04-26): 936 [silent:auth_token_resolve_error] events/day —
\* the bearer token did not resolve to any credential, but the keeper
\* turn proceeded under the caller-supplied alias as if the binding had
\* succeeded.  No terminal entry was recorded, so dashboards could not
\* attribute the identity drift to that branch.
\*
\* This spec models the bug with a [SilentAliasKeep] action and proves
\* the safety invariant [NoSilentAliasKeep] catches it.  Pattern (clean
\* Spec + buggy SpecBuggy gated by a separate Bug action) follows the
\* masc-mcp convention — see KeeperContinueGate.tla and the TLA+ Bug
\* Model entry in /Users/dancer/me/instructions/software-development.md.
\*
\* State space is intentionally minimal: per-keeper booleans for
\* "currently bound" and "ever silently bound", and a single phase
\* slot.  No unbounded sequences, no turn counters — TLC finishes
\* instantly with |Keepers| = 2.

EXTENDS FiniteSets, TLC

CONSTANTS Keepers
ASSUME Keepers # {}

VARIABLES
    turnState,
    authBound,
    silentSkipped,
    authFailedSeen

vars == << turnState, authBound, silentSkipped, authFailedSeen >>

PhaseSet == {"Idle", "AuthResolve"}

TypeOK ==
    /\ turnState \in [Keepers -> PhaseSet]
    /\ authBound \in [Keepers -> BOOLEAN]
    /\ silentSkipped \in [Keepers -> BOOLEAN]
    /\ authFailedSeen \in [Keepers -> BOOLEAN]

Init ==
    /\ turnState = [k \in Keepers |-> "Idle"]
    /\ authBound = [k \in Keepers |-> FALSE]
    /\ silentSkipped = [k \in Keepers |-> FALSE]
    /\ authFailedSeen = [k \in Keepers |-> FALSE]

\* Idle keeper enters AuthResolve when a turn fires.
EnterTurn(k) ==
    /\ turnState[k] = "Idle"
    /\ turnState' = [turnState EXCEPT ![k] = "AuthResolve"]
    /\ UNCHANGED <<authBound, silentSkipped, authFailedSeen>>

\* Bearer token resolved successfully -> bind credential.
AuthOk(k) ==
    /\ turnState[k] = "AuthResolve"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ authBound' = [authBound EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<silentSkipped, authFailedSeen>>

\* Bearer token failed to resolve -> unbind any prior credential and
\* record a terminal entry so the dashboard surfaces the drift.  Phase
\* B PR-2 promotes mcp_server_eio_execute to this transition.
AuthFail(k) ==
    /\ turnState[k] = "AuthResolve"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ authBound' = [authBound EXCEPT ![k] = FALSE]
    /\ authFailedSeen' = [authFailedSeen EXCEPT ![k] = TRUE]
    /\ UNCHANGED silentSkipped

\* THE BUG (pre-Phase B PR-2 mcp_server_eio_execute.ml:318-332):
\* token resolve failed, but the keeper still gets bound under the
\* caller-supplied alias.  No terminal entry is appended.  Phase A F2
\* only counts how often this fires (would_reject metric); the spec
\* below witnesses why Phase B PR-2 must replace this with [AuthFail].
SilentAliasKeep(k) ==
    /\ turnState[k] = "AuthResolve"
    /\ turnState' = [turnState EXCEPT ![k] = "Idle"]
    /\ authBound' = [authBound EXCEPT ![k] = TRUE]
    /\ silentSkipped' = [silentSkipped EXCEPT ![k] = TRUE]
    /\ UNCHANGED authFailedSeen

\* Clean Next: post-Phase-B PR-2 production system.
Next == \E k \in Keepers :
    \/ EnterTurn(k)
    \/ AuthOk(k)
    \/ AuthFail(k)

\* Buggy Next: pre-Phase-B production system.
NextBuggy == \E k \in Keepers :
    \/ EnterTurn(k)
    \/ AuthOk(k)
    \/ AuthFail(k)
    \/ SilentAliasKeep(k)

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* Safety: no keeper has ever taken the silent-alias-keep transition.
\* Clean: trivially holds (action unreachable).
\* Buggy: violated on first SilentAliasKeep firing.
NoSilentAliasKeep ==
    \A k \in Keepers : ~silentSkipped[k]

Safety ==
    /\ TypeOK
    /\ NoSilentAliasKeep

====

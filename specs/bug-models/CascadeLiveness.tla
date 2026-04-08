---- MODULE CascadeLiveness ----
\* Bug Model: Cascade liveness under concurrent keepers with slot contention.
\*
\* Models the interaction between:
\*   - cascade_executor.ml: try_next with slot-aware fallthrough
\*   - provider_throttle.ml: per-provider semaphore (non-blocking on non-last)
\*   - admission_queue.ml: global MASC concurrency gate
\*   - keeper_unified_turn.ml: MASC turn timeout (kills entire OAS cascade)
\*
\* Real-world evidence: 2026-04-08 logs show 7355 GLM calls, 54 Ollama calls,
\* 1538 timeouts.  Ollama failover broken by parse error (Content-Length bug).
\* This spec models the slot/timeout mechanics that determine whether Ollama
\* is reachable at all, independent of the parse bug.

EXTENDS Naturals, FiniteSets

CONSTANTS
    NumKeepers,     \* Number of keepers (e.g. 2)
    NumProviders,   \* Number of providers in cascade (e.g. 3: GLM, GLM-turbo, Ollama)
    MaxSlots,       \* Max concurrent slots per provider (uniform, e.g. 2)
    TurnBudget      \* Max cascade steps before MASC turn timeout fires

ASSUME NumKeepers > 0 /\ NumProviders > 0 /\ MaxSlots > 0 /\ TurnBudget > 0

K == 1..NumKeepers
P == 1..NumProviders

VARIABLES
    kstate,         \* [K -> {"idle","admitted","trying","waiting","done","timeout"}]
    kcascade,       \* [K -> 0..NumProviders]  current provider index (0=not started)
    kattempts,      \* [K -> 0..TurnBudget]  cascade attempts consumed
    phealth,        \* [P -> {"healthy","unhealthy"}]
    pslots,         \* [P -> 0..MaxSlots]  occupied slots
    admitted        \* Number of keepers past the admission gate

vars == <<kstate, kcascade, kattempts, phealth, pslots, admitted>>

\* ── Type Invariant ─────────────────────────────────────

TypeOK ==
    /\ kstate \in [K -> {"idle","admitted","trying","waiting","done","timeout"}]
    /\ kcascade \in [K -> 0..NumProviders]
    /\ kattempts \in [K -> 0..TurnBudget]
    /\ phealth \in [P -> {"healthy","unhealthy"}]
    /\ \A p \in P : pslots[p] >= 0 /\ pslots[p] <= MaxSlots
    /\ admitted >= 0 /\ admitted <= NumKeepers

\* ── Init ───────────────────────────────────────────────

Init ==
    /\ kstate = [k \in K |-> "idle"]
    /\ kcascade = [k \in K |-> 0]
    /\ kattempts = [k \in K |-> 0]
    /\ phealth = [p \in P |-> "healthy"]
    /\ pslots = [p \in P |-> 0]
    /\ admitted = 0

\* ── Actions ────────────────────────────────────────────

\* Keeper enters the admission queue and gets admitted
Admit(k) ==
    /\ kstate[k] = "idle"
    /\ kstate' = [kstate EXCEPT ![k] = "admitted"]
    /\ kcascade' = [kcascade EXCEPT ![k] = 1]
    /\ kattempts' = [kattempts EXCEPT ![k] = 0]
    /\ admitted' = admitted + 1
    /\ UNCHANGED <<phealth, pslots>>

\* Keeper tries non-last provider (non-blocking slot acquire)
TryProvider(k) ==
    LET idx == kcascade[k] IN
    /\ kstate[k] = "admitted"
    /\ idx >= 1 /\ idx < NumProviders  \* non-last only
    /\ kattempts[k] < TurnBudget
    /\ IF phealth[idx] = "healthy" /\ pslots[idx] < MaxSlots
       THEN \* Slot acquired
            /\ pslots' = [pslots EXCEPT ![idx] = @ + 1]
            /\ kstate' = [kstate EXCEPT ![k] = "trying"]
            /\ kattempts' = [kattempts EXCEPT ![k] = @ + 1]
            /\ UNCHANGED <<kcascade, phealth, admitted>>
       ELSE \* Slot full or unhealthy — skip to next (non-blocking)
            /\ kcascade' = [kcascade EXCEPT ![k] = idx + 1]
            /\ kattempts' = [kattempts EXCEPT ![k] = @ + 1]
            /\ UNCHANGED <<kstate, phealth, pslots, admitted>>

\* Keeper tries last provider (blocking: waits for slot)
TryLastProvider(k) ==
    LET idx == kcascade[k] IN
    /\ kstate[k] = "admitted"
    /\ idx = NumProviders
    /\ kattempts[k] < TurnBudget
    /\ IF phealth[idx] = "healthy" /\ pslots[idx] < MaxSlots
       THEN \* Slot acquired
            /\ pslots' = [pslots EXCEPT ![idx] = @ + 1]
            /\ kstate' = [kstate EXCEPT ![k] = "trying"]
            /\ kattempts' = [kattempts EXCEPT ![k] = @ + 1]
            /\ UNCHANGED <<kcascade, phealth, admitted>>
       ELSE \* Block (wait for slot)
            /\ kstate' = [kstate EXCEPT ![k] = "waiting"]
            /\ UNCHANGED <<kcascade, kattempts, phealth, pslots, admitted>>

\* Blocked keeper gets unblocked when slot frees
Unblock(k) ==
    LET idx == kcascade[k] IN
    /\ kstate[k] = "waiting"
    /\ idx = NumProviders
    /\ phealth[idx] = "healthy"
    /\ pslots[idx] < MaxSlots
    /\ pslots' = [pslots EXCEPT ![idx] = @ + 1]
    /\ kstate' = [kstate EXCEPT ![k] = "trying"]
    /\ kattempts' = [kattempts EXCEPT ![k] = @ + 1]
    /\ UNCHANGED <<kcascade, phealth, admitted>>

\* Provider responds OK — slot released, keeper done
ProviderOk(k) ==
    LET idx == kcascade[k] IN
    /\ kstate[k] = "trying"
    /\ pslots' = [pslots EXCEPT ![idx] = @ - 1]
    /\ kstate' = [kstate EXCEPT ![k] = "done"]
    /\ admitted' = admitted - 1
    /\ UNCHANGED <<kcascade, kattempts, phealth>>

\* Provider cascadable error — slot released, try next
ProviderErrorCascade(k) ==
    LET idx == kcascade[k] IN
    /\ kstate[k] = "trying"
    /\ idx < NumProviders
    /\ pslots' = [pslots EXCEPT ![idx] = @ - 1]
    /\ kstate' = [kstate EXCEPT ![k] = "admitted"]
    /\ kcascade' = [kcascade EXCEPT ![k] = idx + 1]
    /\ UNCHANGED <<kattempts, phealth, admitted>>

\* Last provider errors — all models failed, keeper done
ProviderErrorFinal(k) ==
    LET idx == kcascade[k] IN
    /\ kstate[k] = "trying"
    /\ idx = NumProviders
    /\ pslots' = [pslots EXCEPT ![idx] = @ - 1]
    /\ kstate' = [kstate EXCEPT ![k] = "done"]
    /\ admitted' = admitted - 1
    /\ UNCHANGED <<kcascade, kattempts, phealth>>

\* MASC turn timeout — wall-clock based, can fire for ANY active keeper.
\* Models the real 300s timeout that kills the entire OAS cascade.
TurnTimeout(k) ==
    /\ kstate[k] \in {"trying", "waiting", "admitted"}
    /\ kstate' = [kstate EXCEPT ![k] = "timeout"]
    /\ admitted' = admitted - 1
    \* Clean: release slot if held
    /\ IF kstate[k] = "trying"
       THEN pslots' = [pslots EXCEPT ![kcascade[k]] = @ - 1]
       ELSE UNCHANGED pslots
    /\ UNCHANGED <<kcascade, kattempts, phealth>>

\* Provider health toggles (environment)
HealthToggle(p) ==
    /\ phealth' = [phealth EXCEPT ![p] = IF @ = "healthy" THEN "unhealthy" ELSE "healthy"]
    /\ UNCHANGED <<kstate, kcascade, kattempts, pslots, admitted>>

\* ── Next ───────────────────────────────────────────────

Next ==
    \/ \E k \in K :
        \/ Admit(k)
        \/ TryProvider(k)
        \/ TryLastProvider(k)
        \/ Unblock(k)
        \/ ProviderOk(k)
        \/ ProviderErrorCascade(k)
        \/ ProviderErrorFinal(k)
        \/ TurnTimeout(k)
    \/ \E p \in P : HealthToggle(p)

\* Fairness on progress actions only.
\* TurnTimeout and HealthToggle are environment/adversary actions — NOT fair.
\* TurnTimeout models a wall-clock timer that MAY fire, not one that MUST.
ProgressActions(k) ==
    \/ Admit(k) \/ TryProvider(k) \/ TryLastProvider(k) \/ Unblock(k)
    \/ ProviderOk(k) \/ ProviderErrorCascade(k) \/ ProviderErrorFinal(k)

Fairness == \A k \in K : WF_vars(ProgressActions(k))

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety Invariants ──────────────────────────────────

\* Slots never exceed capacity
SlotCapacity == \A p \in P : pslots[p] <= MaxSlots

\* Slots never go negative
SlotNonNeg == \A p \in P : pslots[p] >= 0

\* No phantom slots: slots_used[p] <= keepers in "trying" at provider p
NoPhantomSlots ==
    \A p \in P :
        pslots[p] <= Cardinality({k \in K : kstate[k] = "trying" /\ kcascade[k] = p})

\* Admitted count is consistent
AdmittedOK ==
    admitted = Cardinality({k \in K : kstate[k] \in {"admitted","trying","waiting"}})

\* ── Liveness ───────────────────────────────────────────

\* Every keeper eventually terminates.
\* Requires SF on TurnTimeout: stuck keepers are rescued by wall-clock timeout.
\* WF on ProgressActions alone is insufficient because a keeper waiting on an
\* unhealthy last provider has no enabled progress action.
EventualTermination ==
    \A k \in K : kstate[k] = "idle" ~> kstate[k] \in {"done", "timeout"}

\* Spec with liveness: progress actions are fair, AND timeouts eventually fire
\* for continuously stuck keepers (SF = strong fairness).
FairnessWithTimeout == Fairness /\ (\A k \in K : SF_vars(TurnTimeout(k)))
SpecLive == Init /\ [][Next]_vars /\ FairnessWithTimeout

\* ── Bug Model: Timeout without slot release ────────────

BuggyTurnTimeout(k) ==
    /\ kstate[k] \in {"trying", "waiting", "admitted"}
    /\ kstate' = [kstate EXCEPT ![k] = "timeout"]
    /\ admitted' = admitted - 1
    \* BUG: slot NOT released — Eio cancellation path failure
    /\ UNCHANGED <<kcascade, kattempts, phealth, pslots>>

NextBuggy ==
    \/ \E k \in K :
        \/ Admit(k)
        \/ TryProvider(k)
        \/ TryLastProvider(k)
        \/ Unblock(k)
        \/ ProviderOk(k)
        \/ ProviderErrorCascade(k)
        \/ ProviderErrorFinal(k)
        \/ BuggyTurnTimeout(k)
    \/ \E p \in P : HealthToggle(p)

BuggyProgressActions(k) ==
    \/ Admit(k) \/ TryProvider(k) \/ TryLastProvider(k) \/ Unblock(k)
    \/ ProviderOk(k) \/ ProviderErrorCascade(k) \/ ProviderErrorFinal(k)

FairnessBuggy == \A k \in K : WF_vars(BuggyProgressActions(k))

SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

====

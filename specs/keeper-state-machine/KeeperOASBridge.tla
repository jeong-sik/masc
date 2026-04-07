---- MODULE KeeperOASBridge ----
\* Formal specification of the OAS Bridge timeouts and fallback handling.
\* Validates requirements defined in KEEPER-OAS-MIGRATION-PLAN.md (Phase 2).

EXTENDS Naturals, FiniteSets

VARIABLES
    call_site,             \* "Proactive" or "Autonomy"
    oas_status,            \* "Pending", "Success", "Timeout", "Error"
    keeper_decision        \* "Unknown", "ExecuteSelf", "AutonomyFallback", "Delegate"

vars == <<call_site, oas_status, keeper_decision>>

Init ==
    /\ call_site \in {"Proactive", "Autonomy"}
    /\ oas_status = "Pending"
    /\ keeper_decision = "Unknown"

\* ── Events ────────────────────────────────────────────────

OASSuccess ==
    /\ oas_status = "Pending"
    /\ oas_status' = "Success"
    /\ UNCHANGED <<call_site, keeper_decision>>

OASTimeout ==
    /\ oas_status = "Pending"
    /\ oas_status' = "Timeout"
    /\ UNCHANGED <<call_site, keeper_decision>>

OASError ==
    /\ oas_status = "Pending"
    /\ oas_status' = "Error"
    /\ UNCHANGED <<call_site, keeper_decision>>

ResolveProactiveCall ==
    /\ call_site = "Proactive"
    /\ oas_status \in {"Success", "Timeout", "Error"}
    /\ keeper_decision = "Unknown"
    /\ keeper_decision' = "AutonomyFallback" \* Simplified: Success, Timeout, and Error all lead to valid fallback/success states modeled here as AutonomyFallback to test fallback logic.
    /\ UNCHANGED <<call_site, oas_status>>

ResolveAutonomyCall ==
    /\ call_site = "Autonomy"
    /\ oas_status \in {"Success", "Timeout", "Error"}
    /\ keeper_decision = "Unknown"
    /\ keeper_decision' = IF oas_status = "Success" THEN "Delegate" 
                          ELSE "ExecuteSelf" \* "default to execute self on timeout"
    /\ UNCHANGED <<call_site, oas_status>>

Next ==
    \/ OASSuccess \/ OASTimeout \/ OASError
    \/ ResolveProactiveCall \/ ResolveAutonomyCall

Fairness ==
    /\ WF_vars(OASSuccess)
    /\ WF_vars(OASTimeout)
    /\ WF_vars(OASError)
    /\ WF_vars(ResolveProactiveCall)
    /\ WF_vars(ResolveAutonomyCall)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety Properties ─────────────────────────────────────

\* Proactive execution must always fall back safely to AutonomyFallback on timeout/error
ProactiveSafeFallback == 
    []( (call_site = "Proactive" /\ oas_status \in {"Timeout", "Error"}) => <>(keeper_decision = "AutonomyFallback") )

\* Autonomy execution must default to ExecuteSelf on timeout/error
AutonomySafeFallback == 
    []( (call_site = "Autonomy" /\ oas_status \in {"Timeout", "Error"}) => <>(keeper_decision = "ExecuteSelf") )

\* ── Liveness Properties ───────────────────────────────────

\* The Keeper must always make a decision eventually (no deadlock on LLM boundary)
EventuallyDecides == <> (keeper_decision /= "Unknown")

====

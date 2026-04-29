---- MODULE CascadeResolver ----
\* OAS cascade resolver safety skeleton.
\*
\* Models the health-aware provider resolver that later I5/I6 work
\* will refine with adaptive circuit breaker state.  This skeleton
\* deliberately keeps the state small: a request has one required
\* capability, providers have fixed capability sets, and provider
\* health is supplied by the model cfg.
\*
\* Safety contract:
\*   - never route to a DOWN provider,
\*   - never route to a provider that lacks the requested capability,
\*   - reject instead of routing when no healthy capable provider exists.

EXTENDS TLC, FiniteSets

CONSTANTS
    Providers,
    Capabilities,
    ChatProviders,
    ToolProviders,
    InitialUpProviders,
    NoProvider

HealthStates == {"UP", "DOWN"}
DecisionStates == {"idle", "pending", "routed", "rejected"}
NoCapability == "_none_capability_"

ASSUME ProvidersNonEmpty == Providers # {}
ASSUME CapabilitiesNonEmpty == Capabilities # {}
ASSUME CapabilitiesKnown == Capabilities \subseteq {"chat", "tool"}
ASSUME NoProvider \notin Providers
ASSUME NoCapability \notin Capabilities
ASSUME ChatProvidersShape == ChatProviders \subseteq Providers
ASSUME ToolProvidersShape == ToolProviders \subseteq Providers
ASSUME InitialUpProvidersShape == InitialUpProviders \subseteq Providers

VARIABLES
    health,
    decision,
    request_capability,
    routed_provider

vars == << health, decision, request_capability, routed_provider >>

\* ── Type invariant ───────────────────────────────────────────────
TypeOK ==
    /\ health \in [Providers -> HealthStates]
    /\ decision \in DecisionStates
    /\ request_capability \in Capabilities \cup {NoCapability}
    /\ routed_provider \in Providers \cup {NoProvider}
    /\ decision = "idle" => request_capability = NoCapability
    /\ decision = "idle" => routed_provider = NoProvider
    /\ decision = "pending" => request_capability \in Capabilities
    /\ decision = "pending" => routed_provider = NoProvider
    /\ decision = "routed" => request_capability \in Capabilities
    /\ decision = "routed" => routed_provider \in Providers
    /\ decision = "rejected" => request_capability \in Capabilities
    /\ decision = "rejected" => routed_provider = NoProvider

NeverRouteToDown ==
    decision # "routed" \/ health[routed_provider] = "UP"

ProviderSupports(p, capability) ==
    \/ /\ capability = "chat"
       /\ p \in ChatProviders
    \/ /\ capability = "tool"
       /\ p \in ToolProviders

RouteSupportsCapability ==
    decision # "routed" \/ ProviderSupports(routed_provider, request_capability)

HealthyCapableProviders ==
    { p \in Providers :
        /\ health[p] = "UP"
        /\ ProviderSupports(p, request_capability) }

RejectOnlyWhenNoHealthyCapableProvider ==
    decision # "rejected" \/ HealthyCapableProviders = {}

SafetyInvariant ==
    /\ TypeOK
    /\ NeverRouteToDown
    /\ RouteSupportsCapability
    /\ RejectOnlyWhenNoHealthyCapableProvider

\* ── Init / Next ──────────────────────────────────────────────────
Init ==
    /\ health = [p \in Providers |->
                    IF p \in InitialUpProviders THEN "UP" ELSE "DOWN"]
    /\ decision = "idle"
    /\ request_capability = NoCapability
    /\ routed_provider = NoProvider

StartRequest(capability) ==
    /\ decision = "idle"
    /\ capability \in Capabilities
    /\ request_capability' = capability
    /\ decision' = "pending"
    /\ routed_provider' = NoProvider
    /\ UNCHANGED health

RouteHealthy(p) ==
    /\ decision = "pending"
    /\ p \in Providers
    /\ health[p] = "UP"
    /\ ProviderSupports(p, request_capability)
    /\ decision' = "routed"
    /\ routed_provider' = p
    /\ UNCHANGED << health, request_capability >>

RejectNoRoute ==
    /\ decision = "pending"
    /\ HealthyCapableProviders = {}
    /\ decision' = "rejected"
    /\ routed_provider' = NoProvider
    /\ UNCHANGED << health, request_capability >>

TerminalStutter ==
    /\ decision \in {"routed", "rejected"}
    /\ UNCHANGED vars

Next ==
    \/ \E capability \in Capabilities : StartRequest(capability)
    \/ \E p \in Providers : RouteHealthy(p)
    \/ RejectNoRoute
    \/ TerminalStutter

Spec == Init /\ [][Next]_vars

\* ── Bug model ────────────────────────────────────────────────────
\* ProviderHealthIgnored models resolver logic that filters by
\* capability but forgets to require health=UP.
ProviderHealthIgnored(p) ==
    /\ decision = "pending"
    /\ p \in Providers
    /\ ProviderSupports(p, request_capability)
    /\ decision' = "routed"
    /\ routed_provider' = p
    /\ UNCHANGED << health, request_capability >>

NextBuggy ==
    \/ \E capability \in Capabilities : StartRequest(capability)
    \/ \E p \in Providers : RouteHealthy(p)
    \/ \E p \in Providers : ProviderHealthIgnored(p)
    \/ RejectNoRoute
    \/ TerminalStutter

SpecBuggy == Init /\ [][NextBuggy]_vars

THEOREM Spec => []SafetyInvariant

====

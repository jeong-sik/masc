---- MODULE SandboxDispatch ----
\* Boundary spec for keeper sandbox dispatch routing.
\*
\* Runtime truth (lib/keeper/keeper_tools_oas.ml +
\* lib/keeper/keeper_exec_shell.ml):
\*
\*   - [meta_profile] is the keeper's declared sandbox preference
\*     (Local | Docker).
\*   - [in_playground] gates whether playground-host fallback is even a
\*     candidate route at the dispatch site.
\*   - [dispatched_via] records how the most recent RunBash request was
\*     resolved: None (no dispatch yet), Host, DockerReuse (existing
\*     container), DockerColdstart (new container).
\*
\* The contract this spec proves:
\*   meta_profile = Docker => dispatched_via ∉ {None, Host} once a
\*   request resolves. PR #11594 (run_keeper_bash dispatch SSOT) and
\*   PR #11610 (effective_sandbox_profile invariant) close the silent
\*   host-fallback path at the runtime; this spec proves the routing
\*   contract is enforceable.
\*
\* Why this is its own module (not a ToolCallContract.tla extension):
\*   ToolCallContract is the telemetry boundary contract; its outcome
\*   axis {none, text, tool_use, error} does not carry a "via" axis,
\*   so adding one would force every existing action's UNCHANGED
\*   clauses to grow and obscure the original intent. SandboxDispatch
\*   is the routing-layer contract, kept narrow on the variables that
\*   matter.
\*
\* Bug Model (memory: TLA+ Bug Model pattern):
\*   - Spec       (clean): all dispatches respect the profile contract.
\*   - SpecBuggy:  RunBashHostFallback action lets a Docker-declared
\*     keeper resolve to Host. DockerImpliesDockerVia MUST flag it.
\*
\* Reference: issue #11611 part 2.

EXTENDS TLC

VARIABLES
    meta_profile,
    in_playground,
    request_pending,
    dispatched_via

vars == << meta_profile, in_playground, request_pending, dispatched_via >>

ProfileSet == {"Local", "Docker"}
ViaSet == {"None", "Host", "DockerReuse", "DockerColdstart"}

TypeOK ==
    /\ meta_profile \in ProfileSet
    /\ in_playground \in BOOLEAN
    /\ request_pending \in BOOLEAN
    /\ dispatched_via \in ViaSet

Init ==
    /\ meta_profile \in ProfileSet
    /\ in_playground \in BOOLEAN
    /\ request_pending = FALSE
    /\ dispatched_via = "None"

\* Operator (or supervisor) updates the effective sandbox preference.
\* Only allowed when no request is in flight; otherwise we'd be racing
\* the runtime's decision.
EffectiveResolve(p, ip) ==
    /\ ~ request_pending
    /\ meta_profile' = p
    /\ in_playground' = ip
    /\ dispatched_via' = "None"
    /\ UNCHANGED << request_pending >>

\* A new RunBash request enters the dispatch site.
SubmitRun ==
    /\ ~ request_pending
    /\ request_pending' = TRUE
    /\ dispatched_via' = "None"
    /\ UNCHANGED << meta_profile, in_playground >>

\* Clean dispatch: routing matches the profile contract.
\*   Local  => Host
\*   Docker => DockerReuse | DockerColdstart
\* DockerColdstart is the cold-path branch when no reusable container
\* is present; DockerReuse is the warm-path branch.
DispatchClean(via) ==
    /\ request_pending
    /\ dispatched_via = "None"
    /\ via \in ViaSet \ {"None"}
    /\ \/ /\ meta_profile = "Local"
          /\ via = "Host"
       \/ /\ meta_profile = "Docker"
          /\ via \in {"DockerReuse", "DockerColdstart"}
    /\ dispatched_via' = via
    /\ request_pending' = FALSE
    /\ UNCHANGED << meta_profile, in_playground >>

Next ==
    \/ \E p \in ProfileSet, ip \in BOOLEAN : EffectiveResolve(p, ip)
    \/ SubmitRun
    \/ \E via \in ViaSet \ {"None"} : DispatchClean(via)

Spec == Init /\ [][Next]_vars

\* ── Invariants ────────────────────────────────────────────────────────────

\* I1: DockerImpliesDockerVia. When the keeper declares Docker profile
\* AND a request has already resolved (request_pending = FALSE), the
\* dispatch route MUST be one of {None (no dispatch yet), DockerReuse,
\* DockerColdstart}; never Host. This catches the silent host-fallback
\* class that PR #11594/#11610 root-fix series target.
\*
\* The "None" branch is permitted because the model starts in that
\* state and EffectiveResolve resets it; only resolutions where the
\* runtime actually chose a route are constrained.
DockerImpliesDockerVia ==
    (meta_profile = "Docker" /\ ~ request_pending) =>
        dispatched_via \in {"None", "DockerReuse", "DockerColdstart"}

\* ── Bug actions (used only by SpecBuggy) ──────────────────────────────────

\* B1: RunBashHostFallback. The regression class: a Docker-declared
\* keeper hits the legacy host-fallback path inside [run_docker_hardened_bash]
\* and resolves the request via Host. This is the silent fallback that
\* makes Docker isolation a soft contract; the spec catches it as an
\* invariant violation in <=3 steps.
RunBashHostFallback ==
    /\ request_pending
    /\ dispatched_via = "None"
    /\ meta_profile = "Docker"
    /\ dispatched_via' = "Host"
    /\ request_pending' = FALSE
    /\ UNCHANGED << meta_profile, in_playground >>

NextBuggy ==
    \/ Next
    \/ RunBashHostFallback

SpecBuggy == Init /\ [][NextBuggy]_vars

====

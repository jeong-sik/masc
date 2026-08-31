---- MODULE SandboxDispatch ----
\* Boundary spec for keeper sandbox dispatch routing.
\*
\* Runtime truth (lib/keeper/keeper_sandbox_factory.ml +
\* lib/keeper/keeper_tool_execute_runtime.ml, both routing through
\* Keeper_sandbox_runner.effective_sandbox_profile):
\*
\*   - [meta_profile] is the keeper's declared sandbox preference
\*     (Docker | Micro_vm | Remote_ssh). There is no host arm: the
\*     [Local] profile was removed, so Host is reachable only as the
\*     bug below.
\*   - [in_playground] went with it. It gated whether the playground-host
\*     fallback was a candidate route, and with no host route there is
\*     nothing left for it to gate.
\*   - [dispatched_via] records how the most recent typed Execute request was
\*     resolved: None (no dispatch yet), Host, DockerReuse (existing
\*     container), DockerColdstart (new container), Ssh (Phase 1 remote
\*     lane).
\*
\* The contract this spec proves:
\*   meta_profile \in {Docker, Micro_vm} => dispatched_via ∉ {None, Host} once a
\*   request resolves. PR #11594 (Execute dispatch SSOT) and
\*   PR #11610 (effective_sandbox_profile invariant) close the silent
\*   host-fallback path at the runtime; this spec proves the routing
\*   contract is enforceable.
\*
\* Why this is its own module:
\*   This model covers objective sandbox containment; its outcome
\*   axis {none, text, tool_use, error} does not carry a "via" axis,
\*   so adding one would force every existing action's UNCHANGED
\*   clauses to grow and obscure the original intent. SandboxDispatch
\*   is the routing-layer contract, kept narrow on the variables that
\*   matter.
\*
\* Bug Model (memory: TLA+ Bug Model pattern):
\*   - Spec       (clean): all dispatches respect the profile contract.
\*   - SpecBuggy:  ExecuteHostFallback action lets any declared keeper
\*     resolve to Host. BackendImpliesBackendVia or
\*     RemoteSshImpliesSshVia MUST flag it.
\*
\* Reference: issue #11611 part 2.

EXTENDS TLC

VARIABLES
    meta_profile,
    request_pending,
    dispatched_via

vars == << meta_profile, request_pending, dispatched_via >>

ProfileSet == {"Docker", "Micro_vm", "Remote_ssh"}
BackendProfiles == {"Docker", "Micro_vm"}
ViaSet == {"None", "Host", "DockerReuse", "DockerColdstart", "Ssh"}

TypeOK ==
    /\ meta_profile \in ProfileSet
    /\ request_pending \in BOOLEAN
    /\ dispatched_via \in ViaSet

Init ==
    /\ meta_profile \in ProfileSet
    /\ request_pending = FALSE
    /\ dispatched_via = "None"

\* Operator (or supervisor) updates the effective sandbox preference.
\* Only allowed when no request is in flight; otherwise we'd be racing
\* the runtime's decision.
EffectiveResolve(p) ==
    /\ ~ request_pending
    /\ meta_profile' = p
    /\ dispatched_via' = "None"
    /\ UNCHANGED << request_pending >>

\* A new typed Execute request enters the dispatch site.
SubmitExecute ==
    /\ ~ request_pending
    /\ request_pending' = TRUE
    /\ dispatched_via' = "None"
    /\ UNCHANGED << meta_profile >>

\* Clean dispatch: routing matches the profile contract.
\*   Docker     => DockerReuse | DockerColdstart
\*   Micro_vm   => DockerReuse | DockerColdstart
\*                 (the guest is a backend the same way the container is;
\*                 [Keeper_sandbox_runner.uses_backend] classifies both)
\*   Remote_ssh => Ssh
\* No arm produces Host.
\* DockerColdstart is the cold-path branch when no reusable container
\* is present; DockerReuse is the warm-path branch.
DispatchClean(via) ==
    /\ request_pending
    /\ dispatched_via = "None"
    /\ via \in ViaSet \ {"None"}
    /\ \/ /\ meta_profile \in BackendProfiles
          /\ via \in {"DockerReuse", "DockerColdstart"}
       \/ /\ meta_profile = "Remote_ssh"
          /\ via = "Ssh"
    /\ dispatched_via' = via
    /\ request_pending' = FALSE
    /\ UNCHANGED << meta_profile >>

Next ==
    \/ \E p \in ProfileSet : EffectiveResolve(p)
    \/ SubmitExecute
    \/ \E via \in ViaSet \ {"None"} : DispatchClean(via)

Spec == Init /\ [][Next]_vars

\* ── Invariants ────────────────────────────────────────────────────────────

\* I1: BackendImpliesBackendVia. When the keeper declares a backend
\* profile (Docker or Micro_vm)
\* AND a request has already resolved (request_pending = FALSE), the
\* dispatch route MUST be one of {None (no dispatch yet), DockerReuse,
\* DockerColdstart}; never Host. This catches the silent host-fallback
\* class that PR #11594/#11610 root-fix series target.
\*
\* The "None" branch is permitted because the model starts in that
\* state and EffectiveResolve resets it; only resolutions where the
\* runtime actually chose a route are constrained.
BackendImpliesBackendVia ==
    (meta_profile \in BackendProfiles /\ ~ request_pending) =>
        dispatched_via \in {"None", "DockerReuse", "DockerColdstart"}

\* I2: RemoteSshImpliesSshVia. Same contract for the Phase 1 SSH lane:
\* a Remote_ssh-declared keeper whose request has resolved MUST dispatch
\* via Ssh (or not have dispatched yet); never Host (the local-playground
\* route) and never the Docker vias — a silent lane swap violates
\* RFC-0001 exactly like the host fallback does.
RemoteSshImpliesSshVia ==
    (meta_profile = "Remote_ssh" /\ ~ request_pending) =>
        dispatched_via \in {"None", "Ssh"}

\* ── Bug actions (used only by SpecBuggy) ──────────────────────────────────

\* B1: ExecuteHostFallback. The regression class: a keeper hits a legacy
\* host-fallback path in the typed Execute dispatch layer and resolves the
\* request via Host. Every declared profile is a candidate now, because
\* none of them names a host route; the spec catches it as an invariant
\* violation in <=3 steps.
ExecuteHostFallback ==
    /\ request_pending
    /\ dispatched_via = "None"
    /\ meta_profile \in ProfileSet
    /\ dispatched_via' = "Host"
    /\ request_pending' = FALSE
    /\ UNCHANGED << meta_profile >>

NextBuggy ==
    \/ Next
    \/ ExecuteHostFallback

SpecBuggy == Init /\ [][NextBuggy]_vars

====

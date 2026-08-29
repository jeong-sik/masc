(** Turn-scoped factory for {!Keeper_turn_sandbox_runtime.t}.

    A single keeper turn may dispatch tool calls from different cwds,
    each implying a different [in_playground] state.  The factory
    centralizes the {!Keeper_sandbox_runner.effective_sandbox_profile}
    invariant, evaluates [in_playground] from the call-site [cwd] only for
    runtime workspace reuse, and memoizes one runtime per
    [(in_playground, network_mode)]
    so a Docker container is created at most once per compatible dispatch
    context within a turn.  The runtime can still execute from different cwd
    values via [Keeper_turn_sandbox_runtime.container_cwd_of_host].

    Background: pre-PR-3b, [keeper_tools_agent_core.make_tool_bundle] inspected
    [meta.sandbox_profile] eagerly at turn-start.  The factory still creates
    runtimes lazily at each call site, but freezes its construction meta so
    path resolution and dispatch use one sandbox profile for the whole turn.
    Registry reconciliation takes effect on the next turn; consulting it
    mid-turn can otherwise route a Docker-scoped cwd through Local dispatch.
    The declared sandbox profile remains the execution contract: [Local]
    resolves to [Local_profile] even when DockerPlayground is enabled.

    The dependency on {!Keeper_sandbox_docker} stays acyclic:
    [keeper_sandbox_docker] only consumes [Keeper_turn_sandbox_runtime.t]
    as a parameter and never constructs one itself. *)

type resolve_result =
  | Runtime of Keeper_turn_sandbox_runtime.t
  | No_factory
  | Local_profile
  | Remote_ssh_profile
      (** The effective profile is [Remote_ssh]. Distinct from
          [Local_profile] so no caller can read it as "host execution is
          fine": Docker-shaped consumers fail closed on this constructor,
          and SSH dispatch has its own path. *)

type t

val create :
  ?default_network_override:Keeper_types_profile_sandbox.network_mode ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  t
(** Create an empty factory.  [default_network_override], when supplied,
    is applied to every runtime created via {!resolve}. *)

val resolve :
  t ->
  cwd:string ->
  resolve_result
(** Returns [Runtime runtime] when {!Keeper_sandbox_runner.effective_sandbox_profile}
    yields [Docker] for the construction meta. [in_playground] is
    derived from [cwd] vs the keeper's playground root for runtime workspace
    reuse only. Memoizes per [(in_playground, network_mode, host_root, image)]
    so subsequent compatible calls reuse the same container without crossing
    sandbox-profile or image drift. Registry changes are observed by the next
    turn's factory, never midway through the current turn.

    [Local_profile] is returned when the effective sandbox profile is [Local].
    [Remote_ssh_profile] is returned when it is [Remote_ssh] (there is no
    Docker runtime to resolve for it; consumers fail closed).
    [No_factory] is only produced by {!resolve_opt}. *)

val resolve_opt :
  t option ->
  cwd:string ->
  resolve_result
(** [No_factory] when [t option] is [None]. Otherwise delegates to {!resolve}.
    Lets call sites distinguish "factory missing" from "Local profile". *)

val cleanup : t -> unit
(** Tears down every runtime created via {!resolve}.  Idempotent. *)

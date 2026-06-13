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

    Background: pre-PR-3b, [keeper_tools_oas.make_tool_bundle] inspected
    [meta.sandbox_profile] eagerly at turn-start.  With the factory the
    runtime decision is evaluated per call site, never at turn-start, and
    the memo prevents the cold-start-every-call pattern that lingered after
    PR-3.  Resolution also refreshes the keeper's current registry meta so
    a turn-start factory cannot keep using stale sandbox fields after the
    registry has reconciled TOML/runtime overlays.  The declared sandbox
    profile remains the execution contract: [Local] resolves to [None] even
    when DockerPlayground is enabled.

    The dependency on {!Keeper_sandbox_docker} stays acyclic:
    [keeper_sandbox_docker] only consumes [Keeper_turn_sandbox_runtime.t]
    as a parameter and never constructs one itself. *)

type resolve_result =
  | Runtime of Keeper_turn_sandbox_runtime.t
  | No_factory
  | Local_profile

type t

val create :
  ?default_network_override:Keeper_types_profile_sandbox.network_mode ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?turn_id:int ->
  unit ->
  t
(** Create an empty factory.  [default_network_override], when supplied,
    is applied to every runtime created via {!resolve}. *)

val resolve :
  t ->
  cwd:string ->
  resolve_result
(** Returns [Runtime runtime] when {!Keeper_sandbox_runner.effective_sandbox_profile}
    yields [Docker] for the current registry meta, falling back to the
    construction meta when the keeper is not registered. [in_playground] is
    derived from [cwd] vs the keeper's playground root for runtime workspace
    reuse only. Memoizes per [(in_playground, network_mode, host_root, image)]
    so subsequent compatible calls reuse the same container without crossing
    sandbox-profile or image drift.

    [Local_profile] is returned when the effective sandbox profile is [Local].
    [No_factory] is only produced by {!resolve_opt}. *)

val resolve_opt :
  t option ->
  cwd:string ->
  resolve_result
(** [No_factory] when [t option] is [None]. Otherwise delegates to {!resolve}.
    Lets call sites distinguish "factory missing" from "Local profile". *)

val container_cwd_of_host_opt : t option -> host_cwd:string -> string option
(** Pure Docker CWD projection for response shaping. Unlike {!resolve_opt},
    this does not create or memoize a turn sandbox runtime. *)

val cleanup : t -> unit
(** Tears down every runtime created via {!resolve}.  Idempotent. *)

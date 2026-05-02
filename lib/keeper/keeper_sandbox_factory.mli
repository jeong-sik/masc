(** Turn-scoped factory for {!Keeper_turn_sandbox_runtime.t}.

    A single keeper turn may dispatch tool calls from different cwds,
    each implying a different [in_playground] state.  The factory
    centralizes the {!Keeper_shell_docker.effective_sandbox_profile}
    invariant, evaluates [in_playground] from the call-site [cwd], and
    memoizes one runtime per [(in_playground, network_mode)] so a Docker
    container is created at most once per compatible dispatch context
    within a turn.  The runtime can still execute from different cwd
    values via [Keeper_turn_sandbox_runtime.container_cwd_of_host].

    Background: pre-PR-3b, [keeper_tools_oas.make_tool_bundle] inspected
    [meta.sandbox_profile] eagerly at turn-start and produced [None]
    for [Local], silently bypassing the [DockerPlayground.enabled +
    in_playground=true → Docker upgrade] path that PR-3 (#11610) wired
    into [effective_sandbox_profile].  With the factory the invariant
    is evaluated per call site, never at turn-start, and the memo
    prevents the cold-start-every-call pattern that lingered after
    PR-3.

    The dependency on {!Keeper_shell_docker} stays acyclic:
    [keeper_shell_docker] only consumes [Keeper_turn_sandbox_runtime.t]
    as a parameter and never constructs one itself. *)

type t

val create :
  ?default_network_override:Keeper_types.network_mode ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  unit ->
  t
(** Create an empty factory.  [default_network_override], when supplied,
    is applied to every runtime created via {!resolve} (used by the git
    variant which always inherits the host network). *)

val resolve :
  t ->
  cwd:string ->
  Keeper_turn_sandbox_runtime.t option
(** Returns [Some runtime] when {!Keeper_shell_docker.effective_sandbox_profile}
    yields [Docker] (with [in_playground] derived from [cwd] vs the
    keeper's playground root); [None] when [Local].  Memoizes per
    [(in_playground, network_mode)] so subsequent calls reuse the same
    container. *)

val resolve_opt :
  t option ->
  cwd:string ->
  Keeper_turn_sandbox_runtime.t option
(** Convenience wrapper: [None] when [t option] is [None], otherwise
    delegates to {!resolve}.  Lets call sites that previously matched
    on [Keeper_turn_sandbox_runtime.t option] keep the same shape after
    the factory rewrite. *)

val cleanup : t -> unit
(** Tears down every runtime created via {!resolve}.  Idempotent. *)

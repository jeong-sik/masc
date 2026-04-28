(** Turn-scoped factory for {!Keeper_turn_sandbox_runtime.t}.

    A single keeper turn may dispatch tool calls from different cwds,
    each implying a different [in_playground] state.  The factory
    centralizes the {!Keeper_shell_docker.effective_sandbox_profile}
    invariant and memoizes one runtime per [(in_playground, cwd)] so a
    Docker container is created at most once per distinct dispatch
    context.

    Background: pre-PR-3b, [keeper_tools_oas.make_tool_bundle]
    inspected [meta.sandbox_profile] eagerly at turn-start and produced
    [None] for [Local], silently bypassing the
    [DockerPlayground.enabled + in_playground=true → Docker upgrade]
    path that PR-3 (#11610) wired into [effective_sandbox_profile].
    With the factory the invariant is evaluated per call site, never
    at turn-start.

    The dependency on {!Keeper_shell_docker} stays acyclic:
    [keeper_shell_docker] only consumes [Keeper_turn_sandbox_runtime.t]
    as a parameter and never constructs one itself. *)

type t

val create :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  t

val resolve :
  t ->
  in_playground:bool ->
  cwd:string ->
  Keeper_turn_sandbox_runtime.t option
(** Returns [Some runtime] when {!Keeper_shell_docker.effective_sandbox_profile}
    yields [Docker]; [None] when [Local].  Memoizes per
    [(in_playground, cwd)] so subsequent calls reuse the same
    container. *)

val cleanup : t -> unit
(** Tears down every runtime created via {!resolve}.  Idempotent. *)

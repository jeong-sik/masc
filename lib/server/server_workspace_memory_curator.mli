(** Server-owned shared-memory synthesis. A configured exact-output lane is
    required; the worker neither selects a model nor impersonates a Keeper.
    Committed memory changes coalesce into one pending inventory read. *)
val start : sw:Eio.Switch.t -> base_path:string -> unit

(** Wake an existing owner, including after an explicit lane configuration
    change. This performs no storage or provider work in the caller. *)
type refresh = Queued | No_owner | Unavailable of string

val request : base_path:string -> refresh

val output_schema : Yojson.Safe.t

module For_testing : sig
  (** The lane run itself: HTTP slots as one exact-output flow, then the CLI
      slots through {!Keeper_lane_cli_oneshot.walk}, whose [runner] the
      caller may replace. *)
  val execute
    : ?cli_runner:Keeper_lane_cli_oneshot.runner
    -> base_path:string
    -> resolved:Runtime_exact_output_registry.resolved_lane
    -> rendered_prompt:string
    -> Workspace_memory_context.t
    -> (Yojson.Safe.t * string, string) result

  val start
    : sw:Eio.Switch.t
    -> base_path:string
    -> execute:(rendered_prompt:string -> Workspace_memory_context.t -> (Yojson.Safe.t * string, string) result)
    -> unit
  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end

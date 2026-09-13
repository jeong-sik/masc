(** Server-owned shared-memory synthesis. A configured exact-output lane is
    required; the worker neither selects a model nor impersonates a Keeper.
    Committed memory changes coalesce into one pending inventory read. *)
val start : sw:Eio.Switch.t -> base_path:string -> unit

(** Wake an existing owner, including after an explicit lane configuration
    change. This performs no storage or provider work in the caller. *)
val request : base_path:string -> unit

val lane_id : string
val output_schema : Yojson.Safe.t

module For_testing : sig
  val start
    : sw:Eio.Switch.t
    -> base_path:string
    -> execute:(rendered_prompt:string -> Workspace_memory_context.t -> (Yojson.Safe.t * string, string) result)
    -> unit
  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end

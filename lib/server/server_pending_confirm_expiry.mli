(** Wake full-health and invalidate the workspace waiting inventory on store
    attempts, source transitions and confirmation expiry. Failed observations
    are retried with backoff; healthy sources do not require periodic reads. *)
val start :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> mono_clock:_ Eio.Time.Mono.t ->
  state:Mcp_server.server_state -> unit

module For_testing : sig
  val invalidate_with :
    enqueue:(base_path:string -> unit) -> restore:(base_path:string -> unit) ->
    base_path:string -> unit
  (** Drop the cached operator snapshots, then enqueue the publication and
      restore full health, as the running server does. *)

  val start :
    sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> state:Mcp_server.server_state ->
    read:(Workspace.config -> (Operator_pending_confirm.pending_confirm list, string) result) ->
    invalidate:(base_path:string -> unit) -> unit

  val start_with_sleep :
    sleep_until:(float -> unit) -> sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> state:Mcp_server.server_state ->
    read:(Workspace.config -> (Operator_pending_confirm.pending_confirm list, string) result) ->
    invalidate:(base_path:string -> unit) -> unit

  val start_with_observation :
    sleep_until:(on_armed:(unit -> unit) -> float -> unit) ->
    sleep_retry:(float -> unit) ->
    sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> state:Mcp_server.server_state ->
    read:(Workspace.config -> (Operator_pending_confirm.pending_confirm list, string) result) ->
    invalidate:(base_path:string -> unit) ->
    observation_changed:(base_path:string -> unit) -> unit
end

(** Wake full-health and invalidate the workspace waiting inventory on store
    attempts, source transitions and confirmation expiry, without periodic
    store reads. *)
val start :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> mono_clock:_ Eio.Time.Mono.t ->
  state:Mcp_server.server_state -> unit

module For_testing : sig
  val start :
    sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> state:Mcp_server.server_state ->
    read:(Workspace.config -> (Operator_pending_confirm.pending_confirm list, string) result) ->
    invalidate:(base_path:string -> unit) -> unit

  val start_with_sleep :
    sleep_until:(float -> unit) -> sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> state:Mcp_server.server_state ->
    read:(Workspace.config -> (Operator_pending_confirm.pending_confirm list, string) result) ->
    invalidate:(base_path:string -> unit) -> unit
end

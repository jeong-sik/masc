(** Wake full-health when an operator confirmation expires, without periodic
    store reads. The worker follows workspace generations and observes store
    publications after their lock has been released. *)
val start :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> state:Mcp_server.server_state -> unit

module For_testing : sig
  val start :
    sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> state:Mcp_server.server_state ->
    read:(Workspace.config -> (Operator_pending_confirm.pending_confirm list, string) result) ->
    invalidate:(base_path:string -> unit) -> unit
end

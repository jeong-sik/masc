(** Operator-snapshot proactive refresh loop for dashboard HTTP core. *)

val start_operator_snapshot_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  broadcast_snapshot:
    (Server_dashboard_http_core_operator.operator_snapshot_publication -> unit) ->
  unit
(** Start the cached operator-snapshot proactive refresh loop. *)

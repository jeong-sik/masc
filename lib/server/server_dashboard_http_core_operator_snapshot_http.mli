(** Operator-snapshot dashboard HTTP handler. *)

val operator_snapshot_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  broadcast_snapshot:
    (Server_dashboard_http_core_operator.operator_snapshot_publication -> unit) ->
  Httpun.Request.t ->
  Yojson.Safe.t

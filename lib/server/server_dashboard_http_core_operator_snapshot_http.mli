(** Operator-snapshot dashboard HTTP handler. Parameterized responses compute
    their own rows and carry canonical
    [workspace_identity] paths with [state_ready]. Default cached publications
    retain their own identity and are not relabeled with the current workspace. *)

val operator_snapshot_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  broadcast_snapshot:
    (Server_dashboard_http_core_operator.operator_snapshot_publication -> unit) ->
  Httpun.Request.t ->
  Yojson.Safe.t

(** Operator-digest HTTP handler extracted from [Server_dashboard_http_core]. *)

val operator_digest_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  (Yojson.Safe.t, 'a) result
(** Serve the dashboard operator digest surface, using the cached default
    namespace digest or a parameterized read-only dashboard compute. *)

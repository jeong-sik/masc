(** Operator-digest HTTP handler extracted from [Server_dashboard_http_core]. *)

val operator_digest_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  (Yojson.Safe.t, 'a) result
(** Capture scope and actor before any asynchronous work. Default HTTP reads
    share the captured digest owner, bootstrapping its first current result
    if necessary. Parameterized reads are isolated by captured instance,
    source admission and exact query; they never seed the default owner.
    Their response carries the captured instance and exact actor/query, but
    does not acquire the default canonical publication's ordering metadata.
    No outer time-only route cache may wrap this function. *)

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

val operator_digest_for_actor_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  actor:string ->
  Httpun.Request.t ->
  (Yojson.Safe.t, 'a) result
(** Like {!operator_digest_http_json}, but uses an explicit caller-supplied
    [actor] instead of calling single-user [Server_auth.dashboard_actor_for_request].
    Used by multi-account routes that already authenticated the caller via
    {!Auth_gate}. *)

(** Server_routes_http_routes_channel_gate — HTTP routes for the
    channel-gate connector dashboard surface.

    Wires read-only operator endpoints exposing the state of every
    registered connector. Daemon-side fetch fibers are spawned under
    [~sw]; periodic refresh uses [~clock]. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t

val record_validation_error_metric :
  duration_ms:int -> string -> string -> unit

val resolve_connector_status_name : ?name:string -> unit -> string option

val respond_keeper_tool_json :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Mcp_server.server_state ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  tool_name:string ->
  args:Yojson.Safe.t ->
  unit

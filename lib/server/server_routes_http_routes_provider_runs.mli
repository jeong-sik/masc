(** Server_routes_http_routes_provider_runs — HTTP routes for the
    runtime provider run dashboard surface.

    Wires read-only operator endpoints exposing recent provider run
    samples. Daemon-side fetch fibers are spawned under [~sw]. *)

(** Shared public projection for the provider, cost, and keeper-decision
    dashboard endpoints. [None] means the request path is outside this
    route family. *)
val public_read_json :
  sw:Eio.Switch.t ->
  state:Mcp_server.server_state ->
  Httpun.Request.t ->
  Yojson.Safe.t option

val add_routes :
  sw:Eio.Switch.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

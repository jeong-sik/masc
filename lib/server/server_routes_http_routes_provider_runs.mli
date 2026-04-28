(** Server_routes_http_routes_provider_runs — HTTP routes for the
    cascade provider run dashboard surface.

    Wires read-only operator endpoints exposing recent provider run
    samples. Daemon-side fetch fibers are spawned under [~sw]. *)

val add_routes :
  sw:Eio.Switch.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

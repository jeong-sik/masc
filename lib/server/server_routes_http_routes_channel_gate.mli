(** Server_routes_http_routes_channel_gate — HTTP routes for the
    channel-gate connector dashboard surface.

    Wires read-only operator endpoints exposing connector state
    (Discord, iMessage). Daemon-side fetch fibers are spawned under
    [~sw]; periodic refresh uses [~clock]. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

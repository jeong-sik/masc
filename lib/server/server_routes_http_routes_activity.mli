(** Server_routes_http_routes_activity — HTTP routes for the activity
    graph dashboard surface.

    Wires operator-facing endpoints over the activity event stream.
    Daemon-side aggregation fibers are spawned under [~sw]; periodic
    rollups use [~clock]. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

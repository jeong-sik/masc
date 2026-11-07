(** Server_routes_http_routes_keepers — HTTP routes for keepers.

    Registers [/api/v1/keepers_bulk/*] (fleet-wide operations) and
    [/api/v1/keepers/*] (per-keeper reads, mutations and lifecycle actions). *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

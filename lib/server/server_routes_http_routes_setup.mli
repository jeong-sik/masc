(** Server_routes_http_routes_setup — HTTP routes of the Setup surface
    ([/api/v1/setup/*]). *)

val add_routes :
  sw:Eio.Switch.t -> Http_server_eio.Router.t -> Http_server_eio.Router.t

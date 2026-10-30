(** Loopback-only OAuth HTTP surface for MCP clients. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

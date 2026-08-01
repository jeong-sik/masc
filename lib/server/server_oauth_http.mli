(** Loopback-only OAuth HTTP surface for MCP clients. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val parse_form : string -> ((string * string) list, Auth_oauth.error) result
(** Parse form/query encoding and reject duplicate keys. Exposed for focused
    protocol tests. *)

val html_escape : string -> string
(** Escape an untrusted value for an HTML text or quoted attribute context. *)

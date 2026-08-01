(** Loopback-only OAuth HTTP surface for MCP clients. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val parse_form : string -> ((string * string) list, Auth_oauth.error) result
(** Parse form/query encoding and reject duplicate keys. Exposed for focused
    protocol tests. *)

val html_escape : string -> string
(** Escape an untrusted value for an HTML text or quoted attribute context. *)

val ensure_optional_string_set :
  (string * Yojson.Safe.t) list ->
  string ->
  string list ->
  (unit, Auth_oauth.error) result
(** Require an optional JSON string array to equal the expected set exactly,
    rejecting duplicates. Exposed for focused protocol tests. *)

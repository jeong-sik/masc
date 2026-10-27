(** OAuth discovery values derived from the admitted request authority.

    No function in this module reads raw Host/Forwarded headers. *)

val issuer : Server_request_authority.authority -> string
(** The authorization server issuer identifier (RFC 8414 section 2). The
    authorization response carries the same value as [iss] (RFC 9207). *)

val resource : Server_request_authority.authority -> string
val protected_resource_metadata_url : Server_request_authority.authority -> string
val challenge_for_authority : Server_request_authority.authority -> string
(** OAuth discovery challenge when built-in OAuth is enabled on loopback;
    otherwise the compatibility challenge [Bearer]. *)

val protected_resource_json :
  Server_request_authority.authority -> Yojson.Safe.t

val authorization_server_json :
  Server_request_authority.authority -> Yojson.Safe.t

val loopback_authority : Server_request_authority.authority -> bool
(** Built-in OAuth authorization is available only when the admitted authority
    is the actual configured listener and that listener is loopback. An
    explicit trusted Host cannot turn a public listener into a loopback OAuth
    endpoint. *)

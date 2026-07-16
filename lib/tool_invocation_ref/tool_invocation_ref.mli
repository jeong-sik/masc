(** Exact producer identity for a tool invocation crossing into MASC.

    This type owns correlation only. It does not authorize an effect and does
    not infer identity from tool names, arguments, timestamps, or hashes. *)

type t

type error = Empty_mcp_session_id

type decode_error =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_field of string
  | Expected_string of string
  | Invalid_source of string
  | Invalid_request_id of Mcp_transport_protocol.request_id_error
  | Invalid_identity of error

val external_mcp :
  request_id:Mcp_transport_protocol.request_id ->
  session_id:string ->
  (t, error) result
(** Builds an external MCP identity from the exact typed JSON-RPC request id
    and the stable transport session id. *)

val to_yojson : t -> Yojson.Safe.t
(** Typed, inspectable projection. *)

val of_yojson : Yojson.Safe.t -> (t, decode_error) result
(** Restores the exact producer identity from its closed projection. Unknown,
    duplicate, or malformed fields are rejected rather than ignored. *)

val equal : t -> t -> bool

val error_to_string : error -> string
val decode_error_to_string : decode_error -> string

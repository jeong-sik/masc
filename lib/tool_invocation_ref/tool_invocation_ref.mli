(** Exact producer identity for a tool invocation crossing into MASC.

    This type owns correlation only. It does not authorize an effect and does
    not infer identity from tool names, arguments, timestamps, or hashes. *)

type t

type error = Empty_mcp_session_id

val external_mcp :
  request_id:Mcp_transport_protocol.request_id ->
  session_id:string ->
  (t, error) result
(** Builds an external MCP identity from the exact typed JSON-RPC request id
    and the stable transport session id. *)

val to_yojson : t -> Yojson.Safe.t
(** Typed, inspectable projection. *)

val equal : t -> t -> bool

val error_to_string : error -> string

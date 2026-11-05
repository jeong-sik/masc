(** JSON codec for the [Checkpoint.mcp_sessions] field.
    [Agent_checkpoint.build_checkpoint] writes an empty list, and
    [Agent.resume] takes its tools from the caller.

    @stability Internal
    @since 0.93.1 *)

open Types

type transport_kind =
  | Stdio
  | Http

type info =
  { server_name : string
  ; command : string
  ; args : string list
  ; env : (string * string) list
  ; http_base_url : string option
  ; http_headers : (string * string) list
  ; tool_schemas : tool_schema list
  ; transport_kind : transport_kind
  }

(** {2 JSON serialization} *)

val info_to_json : info -> Yojson.Safe.t
val info_of_json : Yojson.Safe.t -> (info, Error.t) result
val info_list_to_json : info list -> Yojson.Safe.t
val info_list_of_json : Yojson.Safe.t -> (info list, Error.t) result

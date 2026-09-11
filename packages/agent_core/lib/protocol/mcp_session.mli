(** MCP session capture for the checkpoint record.

    Captures the serializable parts of MCP connections (specs + tool schemas)
    onto [Checkpoint.mcp_sessions]. Nothing reconnects from them: [Agent.resume]
    takes its tools from the caller.

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

val capture : Mcp.managed -> info
val capture_all : Mcp.managed list -> info list
val to_server_spec : info -> Mcp.server_spec

(** {2 JSON serialization} *)

val info_to_json : info -> Yojson.Safe.t
val info_of_json : Yojson.Safe.t -> (info, Error.t) result
val info_list_to_json : info list -> Yojson.Safe.t
val info_list_of_json : Yojson.Safe.t -> (info list, Error.t) result

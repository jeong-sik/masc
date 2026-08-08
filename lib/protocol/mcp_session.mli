(** MCP session persistence -- capture and restore server connection info.

    Captures serializable parts of MCP connections (specs + tool schemas)
    for checkpoint/resume cycles.

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

val reconnect_all
  :  sw:Eio.Switch.t
  -> mgr:_ Eio.Process.mgr
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> info list
  -> Mcp.managed list * (info * Error.sdk_error) list

(** {2 JSON serialization} *)

val info_to_json : info -> Yojson.Safe.t
val info_of_json : Yojson.Safe.t -> (info, Error.sdk_error) result
val info_list_to_json : info list -> Yojson.Safe.t
val info_list_of_json : Yojson.Safe.t -> (info list, Error.sdk_error) result

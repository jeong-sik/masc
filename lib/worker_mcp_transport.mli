(** Worker_mcp_transport — JSON-RPC communication, MCP tool listing, and HTTP transport for worker agents. *)

type tool_exec_result = {
  text : string;
  is_error : bool;
}

val strip_mcp_prefix : string -> string
val unique_preserve_order : string list -> string list
val has_agent_name_field : Types.tool_schema -> bool

val inject_default_agent_name :
  worker_name:string ->
  schema:Types.tool_schema option ->
  Yojson.Safe.t ->
  Yojson.Safe.t

val extract_prompt_block :
  start_marker:string -> end_marker:string -> string -> string option

val inject_prompt_full_context :
  prompt:string -> tool_name:string -> Yojson.Safe.t -> Yojson.Safe.t

val masc_http_base_url : unit -> string

val call_jsonrpc :
  sw:Eio.Switch.t ->
  auth_token:string option ->
  session_id:string ->
  method_name:string ->
  params:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val call_masc_tool :
  sw:Eio.Switch.t ->
  auth_token:string option ->
  session_id:string ->
  tool_name:string ->
  args:Yojson.Safe.t ->
  (tool_exec_result, string) result

val list_masc_tools :
  sw:Eio.Switch.t ->
  auth_token:string option ->
  session_id:string ->
  ?names:string list option ->
  unit ->
  (Types.tool_schema list, string) result

val tool_schema_of_name :
  Types.tool_schema list -> string -> Types.tool_schema option

val tool_defs_of_schemas :
  Types.tool_schema list -> Llm_client.tool_def list

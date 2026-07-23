(** Mcp_tool_runtime_types — shared types for MCP server-local tool modules.

    Extracted to avoid circular dependencies between
    [mcp_tool_runtime], [mcp_tool_runtime_workspace], and
    [mcp_tool_runtime_comm]. *)

type tool_result = Tool_result.result
(** Structural alias — all MCP runtime handlers return
    [Tool_result.result option]. *)

(** Context record capturing all bindings from [execute_tool_eio]
    that the MCP runtime block needs. Pure data — callers
    populate all fields. *)
type context = {
  config : Workspace.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  mcp_session_id : string option;
  record_mcp_session_agent : string -> unit;
      (** Record the resolved agent name for this MCP session. *)
  wait_for_message :
    Session.registry ->
    agent_name:string ->
    timeout:float ->
    Yojson.Safe.t option;
      (** Wait for a message from a given agent. *)
  load_mcp_sessions :
    Workspace.config -> Mcp_session_store.mcp_session_record list;
  save_mcp_sessions :
    Workspace.config ->
    Mcp_session_store.mcp_session_record list ->
    unit;
}

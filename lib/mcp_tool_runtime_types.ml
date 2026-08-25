(** Mcp_tool_runtime_types — shared types for MCP server-local tool modules.

    Extracted to avoid circular dependencies between
    mcp_tool_runtime, mcp_tool_runtime_workspace, and mcp_tool_runtime_comm. *)

type tool_result = Tool_result.result

(** Context record capturing all bindings from execute_tool_eio
    that the MCP runtime block needs. *)
type context = {
  config : Workspace.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  mcp_session_id : string option;
  (** Record the resolved agent name for this MCP session. *)
  record_mcp_session_agent : string -> unit;
  (** Wait for a message from a given agent *)
  wait_for_message :
    Session.registry ->
    agent_name:string ->
    timeout:float ->
    Yojson.Safe.t option;
}

(** Helper: run subprocess — uses [Dispatch] caller (default 120s).
    Dead code since 2026-05; removed during RFC-0062 Phase 4c-2
    (tool_result migration from (bool * string) to Tool_result.result).
    If needed again, add ~tool_name ~start_time and return Tool_result.result. *)


(** Mcp_tool_runtime — MCP server-local tool runtime.

    Delegates to sub-modules for workspace, comm, and board tool handling.
    Keeps MCP-only server helpers that need per-request server state.

    @since 0.1.0 *)

(** {1 Types} (re-exported from Mcp_tool_runtime_types) *)

type tool_result = Mcp_tool_runtime_types.tool_result

type context = Mcp_tool_runtime_types.context = {
  config : Workspace.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  mcp_session_id : string option;
  record_mcp_session_agent : string -> unit;
  wait_for_message :
    Session.registry ->
    agent_name:string ->
    timeout:float ->
    Yojson.Safe.t option;
  governance_defaults : string -> Mcp_server_eio_governance.governance_config;
  save_governance :
    Workspace.config ->
    Mcp_server_eio_governance.governance_config ->
    (unit, string) result;
  load_mcp_sessions :
    Workspace.config -> Mcp_server_eio_governance.mcp_session_record list;
  save_mcp_sessions :
    Workspace.config ->
    Mcp_server_eio_governance.mcp_session_record list ->
    (unit, string) result;
}

(** {1 Dispatch} *)

val dispatch : context -> name:string -> Tool_result.result option

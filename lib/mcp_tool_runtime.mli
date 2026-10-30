
(** Mcp_tool_runtime — MCP server-local tool runtime.

    Delegates to sub-modules for workspace, comm, and board tool handling.
    Keeps MCP-only server helpers that need per-request server state.

    @since 0.1.0 *)

(** {1 Types}

    Re-exported from [Mcp_tool_runtime_types]. *)

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
}

(** {1 Dispatch} *)

val dispatch : context -> name:string -> Tool_result.result option

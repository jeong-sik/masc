(** Tool_inline_dispatch_types — shared types for inline dispatch modules.

    Extracted to avoid circular dependencies between
    [tool_inline_dispatch], [tool_inline_dispatch_workspace], and
    [tool_inline_dispatch_comm]. *)

type tool_result = Tool_result.result
(** Structural alias — all inline dispatch handlers return
    [Tool_result.result option]. *)

(** Context record capturing all bindings from [execute_tool_eio]
    that the remaining inline dispatch block actually needs. Pure data —
    callers populate all fields. *)
type context = {
  config : Workspace.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  load_mcp_sessions :
    Workspace.config -> Mcp_server_eio_governance.mcp_session_record list;
  save_mcp_sessions :
    Workspace.config ->
    Mcp_server_eio_governance.mcp_session_record list ->
    unit;
}

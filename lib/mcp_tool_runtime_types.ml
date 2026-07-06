module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

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
  (** Governance types/helpers — passed in to avoid circular deps *)
  governance_defaults : string -> Mcp_server_eio_governance.governance_config;
  save_governance :
    Workspace.config ->
    Mcp_server_eio_governance.governance_config ->
    (unit, string) result;
  load_mcp_sessions : Workspace.config -> Mcp_server_eio_governance.mcp_session_record list;
  save_mcp_sessions :
    Workspace.config ->
    Mcp_server_eio_governance.mcp_session_record list ->
    (unit, string) result;
}

(** Helper: run subprocess — uses [Dispatch] caller (default 120s).
    Dead code since 2026-05; removed during RFC-0062 Phase 4c-2
    (tool_result migration from (bool * string) to Tool_result.result).
    If needed again, add ~tool_name ~start_time and return Tool_result.result. *)

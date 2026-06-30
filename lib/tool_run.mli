
(** Run Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    4 tools: run_init, run_plan, run_get, run_list
*)

(** Tool handler context *)
type context = {
  config: Workspace.config;
  agent_name: string option;
}

(** {1 Individual Handlers} *)

val handle_run_init : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_run_plan : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_run_get : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_run_list : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result

(** {1 Dispatcher} *)

(** Dispatch run tool by name. Returns None if not a run tool. *)
(** Tool schemas for MCP tools/list. Aliases {!Tool_schemas_run.schemas};
    keep the run-tool schema contract in that SSOT. *)
val schemas : Masc_domain.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option

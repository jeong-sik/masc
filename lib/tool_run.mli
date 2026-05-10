
(** Run Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    6 tools: run_init, run_plan, run_log, run_deliverable, run_get, run_list
*)

(** Tool handler context *)
type context = {
  config: Coord.config;
}

(** {1 Individual Handlers} *)

val handle_run_init : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_run_plan : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_run_log : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_run_deliverable : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_run_get : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_run_list : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t

(** {1 Dispatcher} *)

(** Dispatch run tool by name. Returns None if not a run tool. *)
(** Tool schemas for MCP tools/list *)
val schemas : Masc_domain.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.t option

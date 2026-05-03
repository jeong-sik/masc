
(** Run Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    6 tools: run_init, run_plan, run_log, run_deliverable, run_get, run_list
*)

(** Tool handler context *)
type context = {
  config: Coord.config;
}

(** Tool result type *)
type tool_result = bool * string

(** {1 Individual Handlers} *)

val handle_run_init : context -> Yojson.Safe.t -> tool_result
val handle_run_plan : context -> Yojson.Safe.t -> tool_result
val handle_run_log : context -> Yojson.Safe.t -> tool_result
val handle_run_deliverable : context -> Yojson.Safe.t -> tool_result
val handle_run_get : context -> Yojson.Safe.t -> tool_result
val handle_run_list : context -> Yojson.Safe.t -> tool_result

(** {1 Dispatcher} *)

(** Dispatch run tool by name. Returns None if not a run tool. *)
(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option

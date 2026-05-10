
(** Plan Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    9 tools: plan_init, plan_update, note_add, deliver, plan_get,
             plan_set_task, plan_get_task, plan_clear_task
*)

(** Tool handler context *)
type context = {
  config: Coord.config;
}

(** Tool result type *)
type tool_result = bool * string

(** {1 Individual Handlers} *)

val handle_plan_init : context -> Yojson.Safe.t -> tool_result
val handle_plan_update : context -> Yojson.Safe.t -> tool_result
val handle_note_add : context -> Yojson.Safe.t -> tool_result
val handle_deliver : context -> Yojson.Safe.t -> tool_result
val handle_plan_get : context -> Yojson.Safe.t -> tool_result
val handle_plan_set_task : context -> Yojson.Safe.t -> tool_result
val handle_plan_get_task : context -> Yojson.Safe.t -> tool_result
val handle_plan_clear_task : context -> Yojson.Safe.t -> tool_result

(** {1 Dispatcher} *)

(** Dispatch plan tool by name. Returns None if not a plan tool. *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.t option

val schemas : Masc_domain.tool_schema list

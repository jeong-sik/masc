
(** Plan Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    8 tools: plan_init, plan_update, note_add, deliver, plan_get,
             plan_set_task, plan_get_task, plan_clear_task
*)

(** Tool handler context *)
type context = {
  config: Coord.config;
}

(** {1 Individual Handlers} *)

val handle_plan_init : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_plan_update : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_note_add : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_deliver : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_plan_get : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_plan_set_task : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_plan_get_task : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_plan_clear_task : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t

(** {1 Dispatcher} *)

(** Dispatch plan tool by name. Returns None if not a plan tool. *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.t option

val schemas : Masc_domain.tool_schema list

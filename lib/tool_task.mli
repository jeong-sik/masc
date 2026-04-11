(** Tool_task - Core task CRUD operations *)

type tool_result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

val handle_add_task : context -> Yojson.Safe.t -> tool_result
val handle_batch_add_tasks : context -> Yojson.Safe.t -> tool_result
val handle_claim : context -> Yojson.Safe.t -> tool_result
val handle_claim_next : context -> Yojson.Safe.t -> tool_result
val handle_release : context -> Yojson.Safe.t -> tool_result
val handle_done : context -> Yojson.Safe.t -> tool_result
val handle_cancel_task : context -> Yojson.Safe.t -> tool_result
val handle_transition : context -> Yojson.Safe.t -> tool_result
val handle_update_priority : context -> Yojson.Safe.t -> tool_result
val handle_tasks : context -> Yojson.Safe.t -> tool_result
val handle_task_history : context -> Yojson.Safe.t -> tool_result
val handle_archive_view : context -> Yojson.Safe.t -> tool_result

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option

val schemas : Types.tool_schema list

(** Tool_fire_task — Fire-and-forget background task execution.

    Single MCP call: create task, optionally provision worktree,
    spawn agent in background fiber. Caller gets task_id immediately. *)

(** Context required by the fire_task tool. *)
type context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
}

(** Tool dispatch. Returns [Some (success, message)] or [None] for unknown tools. *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> (bool * string) option

(** Exported schemas for registration. *)
val schemas : Types.tool_schema list

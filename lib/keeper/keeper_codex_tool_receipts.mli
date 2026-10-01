(** Bind a Codex producer's active dynamic-tool block to its exact host
    invocation. Native tools have no host execution receipt. *)
type t
val create :
  notify:(block_index:int -> tool_call_id:string -> execution_id:Ids.Execution_id.t -> unit) -> t
val start : t -> call_id:string -> block_index:int -> unit
val finish : t -> call_id:string -> unit
val hooks : t -> Agent_core.Hooks.hooks -> Agent_core.Hooks.hooks
(** The pre-hook binds the invocation before execution. The post-hook reports
    only a committed receipt, before the event bus consumes its join. *)

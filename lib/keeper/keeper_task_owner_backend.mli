(** Keeper-owned task owner hooks behind the tool/task boundary. *)

val is_keeper_agent_identity :
  Workspace.config -> agent_name:string -> bool

val sync_current_task_binding : Workspace.config -> agent_name:string -> unit
val install_hooks : unit -> unit

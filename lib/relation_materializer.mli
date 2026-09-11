(** Relation_materializer — agent collaboration lifecycle hooks.

    Provides workspace lifecycle hooks wired by {!Workspace_hooks}
    for session end and task completion.

    @since 2.112.0 *)

val on_agent_session_ended :
  leaving_agent:string ->
  active_agents:string list ->
  unit
(** Workspace hook invoked when an agent session ends. *)

val on_task_done :
  assignee:string ->
  active_agents:string list ->
  unit
(** Workspace hook invoked when a task completes. *)

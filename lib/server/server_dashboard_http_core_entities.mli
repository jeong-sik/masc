val dashboard_shell_status_json : Workspace.config -> Yojson.Safe.t
val dashboard_task_json : Workspace.config -> Masc_domain.task -> Yojson.Safe.t
val dashboard_agent_json : Masc_domain.agent -> Yojson.Safe.t
val dashboard_message_json : Masc_domain.message -> Yojson.Safe.t
val dashboard_tasks_safe : Workspace.config -> Masc_domain.task list
val dashboard_agents_safe : Workspace.config -> Masc_domain.agent list

val dashboard_general_agent_count_light : Workspace.config -> int
(** Cheap active non-keeper agent count for [/api/v1/dashboard/shell?light=true].
    Reads only the small status/type summary fields instead of materializing
    full agent records or running repair. *)

val dashboard_messages_safe :
  Workspace.config -> since_seq:int -> limit:int -> Masc_domain.message list

val dashboard_general_agent_count : Masc_domain.agent list -> int
val provider_capacity_json : unit -> Yojson.Safe.t

val dashboard_shell_status_json : Coord.config -> Yojson.Safe.t
val dashboard_task_json : Coord.config -> Masc_domain.task -> Yojson.Safe.t
val dashboard_agent_json : Masc_domain.agent -> Yojson.Safe.t
val dashboard_message_json : Masc_domain.message -> Yojson.Safe.t
val dashboard_tasks_safe : Coord.config -> Masc_domain.task list
val dashboard_agents_safe : Coord.config -> Masc_domain.agent list

val dashboard_messages_safe :
  Coord.config -> since_seq:int -> limit:int -> Masc_domain.message list

val dashboard_general_agent_count : Masc_domain.agent list -> int
val provider_capacity_json : unit -> Yojson.Safe.t

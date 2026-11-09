val dashboard_shell_status_json : Workspace.config -> Yojson.Safe.t
val dashboard_agent_json : Masc_domain.agent -> Yojson.Safe.t

val dashboard_client_json : Masc_domain.agent * Workspace.agent_source -> Yojson.Safe.t
(** {!dashboard_agent_json} for a Clients roster row, with [session_bound_at]
    and [last_seen] [null] unless the row is an agent record: a Keeper
    registry row carries the time of the read there, and a workspace-state
    row the workspace's start — neither is a fact about the client. *)
val dashboard_message_json : Masc_domain.message -> Yojson.Safe.t
val dashboard_tasks_safe : Workspace.config -> Masc_domain.task list
val dashboard_agents_safe : Workspace.config -> Masc_domain.agent list

val dashboard_general_agent_count_light : Workspace.config -> int
(** Cheap active non-keeper agent count for [/api/v1/dashboard/shell?light=true].
    Reads only the small status/type summary fields instead of materializing
    full agent records or running repair. *)

val dashboard_general_agent_count : Masc_domain.agent list -> int
val provider_capacity_json : unit -> Yojson.Safe.t

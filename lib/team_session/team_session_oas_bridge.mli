(** Team_session_oas_bridge — Bridge between MASC team session and OAS Swarm.
    Phase C-1 of MASC->OAS migration.
    @since 2.124.0 *)

module Swarm = Agent_sdk_swarm

val role_of_worker_class :
  Team_session_types.worker_class option -> Swarm.Swarm_types.agent_role

val role_of_spawn_role :
  worker_class:Team_session_types.worker_class option ->
  string option -> Swarm.Swarm_types.agent_role

val mode_of_orchestration :
  Team_session_types.orchestration_mode -> Swarm.Swarm_types.orchestration_mode

val cascade_of_worker :
  session_cascade:string list ->
  Team_session_types.planned_worker -> string

val planned_worker_to_entry :
  config:Room.config ->
  session_cascade:string list ->
  masc_tools:Types.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  Team_session_types.planned_worker -> Swarm.Swarm_types.agent_entry

val session_to_swarm_config :
  config:Room.config ->
  masc_tools:Types.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  Team_session_types.session -> Swarm.Swarm_types.swarm_config

val apply_swarm_result :
  Team_session_types.session ->
  Swarm.Swarm_types.swarm_result -> Team_session_types.session

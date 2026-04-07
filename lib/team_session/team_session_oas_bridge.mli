(** Team_session_oas_bridge — MASC-side projection layer over OAS Swarm.

    Two lossy projections:

    {b planned_worker (23 fields) -> agent_entry (4 fields)}

    Direct: [spawn_agent] -> [name], [spawn_role]/[worker_class] -> [role].
    Closure-captured: [max_turns], [spawn_model] (cascade selection).

    {b session (47 fields) -> swarm_config (12 fields)}

    Direct: [goal] -> [prompt], [orchestration_mode] -> [mode],
    [duration_seconds] -> [timeout_sec]/[budget], [planned_workers] -> [entries].
    Dropped: [operation_id], [report_formats], runtime metrics,
    outcome metrics, post-execution fields.

    OAS remains generic orchestration/runtime substrate; MASC delivery,
    workflow, and proof semantics stay in team-session state.

    @since 2.124.0 *)

val supported_local_worker_tool_names : string list
(** Canonical list of tool names supported by local workers in team sessions.
    Exposed for parity testing against [Tool_catalog.tools_for_surface Local_worker]. *)

val supported_local_worker_tool_names_for_scope :
  Team_session_types.execution_scope option -> string list

val supported_local_worker_tools :
  unit -> (Types.tool_schema list, string) result

val supported_local_worker_tools_for_scope :
  Team_session_types.execution_scope option ->
  (Types.tool_schema list, string) result

val dispatch_supported_tool :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:Room.config ->
  name:string ->
  args:Yojson.Safe.t ->
  bool * string

val run_repair_loop_until_terminal_with :
  dispatch_tool:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  Yojson.Safe.t ->
  bool * string

val run_repair_loop_until_terminal :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:Room.config ->
  Yojson.Safe.t ->
  bool * string

val slot_aware_concurrency_cap :
  entry_count:int ->
  selection_count:int ->
  all_discovered:bool ->
  endpoints_found:int ->
  total:int ->
  int

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

val telemetry_of_run_result :
  Oas_worker.run_result -> Swarm.Swarm_types.agent_telemetry

val is_safe_worker_run_id : string -> bool

val planned_worker_to_entry :
  config:Room.config ->
  session_id:string ->
  session_cascade:string list ->
  masc_tools:Types.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  Team_session_types.planned_worker -> Swarm.Swarm_types.agent_entry

val session_to_swarm_config :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:Room.config ->
  masc_tools:Types.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  Team_session_types.session -> Swarm.Swarm_types.swarm_config

val apply_swarm_result :
  Team_session_types.session ->
  Swarm.Swarm_types.swarm_result -> Team_session_types.session

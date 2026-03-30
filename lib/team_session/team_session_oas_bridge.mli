(** Team_session_oas_bridge — Bridge between MASC team session and OAS Swarm.

    Two lossy projections:

    {b planned_worker (23 fields) -> agent_entry (4 fields)}

    Direct: [spawn_agent] -> [name], [spawn_role]/[worker_class] -> [role].
    Closure-captured: [max_turns], [spawn_model] (cascade selection).
    Preserved in Collaboration.t.metadata["worker_specs"]: the full
    [planned_worker] record as JSON per worker.
    Metadata-only at the OAS boundary: 18 fields (runtime_actor,
    thinking_enabled/budget, timeout_seconds, capsule_mode, lane_id,
    controller_level, control_domain, supervisor_actor, model_tier,
    task_profile, risk_level, routing_confidence/reason/escalated, etc.).

    {b session (47 fields) -> swarm_config (12 fields)}

    Direct: [goal] -> [prompt], [orchestration_mode] -> [mode],
    [duration_seconds] -> [timeout_sec]/[budget], [planned_workers] -> [entries].
    Via Collaboration.t: [session_id] -> [id], [status] -> [phase],
    [planned_workers] -> [participants].
    Preserved in Collaboration.t.metadata: 21+ session fields as JSON
    (room_id, created_by, origin_kind, execution_scope, control_profile,
    scale_profile, model_cascade, fallback_policy, etc.).
    Dropped: [operation_id], [report_formats], runtime metrics
    (broadcast_count..cascade_failed), outcome metrics
    (baseline_done_counts..final_done_delta_by_agent),
    post-execution fields (generated_report, delivery_contract,
    latest_delivery_verdict).

    See [PROJECTION_MAP.md] for the complete field-by-field table.

    Phase C-1 of MASC->OAS migration.
    @since 2.124.0 *)

module Swarm = Agent_sdk_swarm

val supported_local_worker_tools :
  unit -> (Types.tool_schema list, string) result

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

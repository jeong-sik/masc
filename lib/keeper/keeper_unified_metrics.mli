(** Keeper_unified_metrics — Observation helpers, decision records, and
    metrics update for the unified keeper cycle.

    Extracted from keeper_unified_turn.ml.

    @since 0.120.0 *)

(** Derive the trigger list from the observation. *)
val observed_triggers_of_observation :
  ?meta:Keeper_types.keeper_meta ->
  Keeper_world_observation.world_observation ->
  string list

(** Derive the affordance list from the observation. *)
val observed_affordances_of_observation :
  ?meta:Keeper_types.keeper_meta ->
  Keeper_world_observation.world_observation ->
  string list

type turn_mode =
  | Tool_use
  | Text_response
  | Skip_text
  | Noop

val update_metrics_from_result :
  Keeper_types.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  ?is_autonomous_turn:bool ->
  ?update_proactive_rt:bool ->
  ?social_state:Keeper_social_model.social_state ->
  ?social_transition_reason:string ->
  Keeper_agent_run.run_result ->
  Keeper_types.keeper_meta

val update_metrics_from_failure :
  Keeper_types.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  ?is_transient:bool ->
  ?social_state:Keeper_social_model.social_state ->
  ?social_transition_reason:string ->
  ?sdk_error:Oas.Error.sdk_error ->
  unit ->
  Keeper_types.keeper_meta

val append_metrics_snapshot :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  result:Keeper_agent_run.run_result ->
  latency_ms:int ->
  turn_cost:float ->
  turn_generation:int ->
  channel:string ->
  snapshot_source:string ->
  context_ratio:float ->
  context_tokens:int ->
  context_max:int ->
  message_count:int ->
  compaction:Keeper_exec_context.compaction_event ->
  handoff_json:Yojson.Safe.t option ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  unit ->
  unit

val append_decision_record :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  latency_ms:int ->
  ?semaphore_wait_ms:int ->
  outcome:string ->
  ?turn_mode:turn_mode ->
  ?social_state:Keeper_social_model.social_state ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  ?result:Keeper_agent_run.run_result option ->
  ?error:string ->
  unit ->
  unit

val broadcast_lifecycle_events :
  name:string ->
  turn_generation:int ->
  compaction:Keeper_exec_context.compaction_event ->
  handoff_json:Yojson.Safe.t option ->
  unit

val has_substantive_tool_calls : string list -> bool

val visible_run_validation :
  Keeper_agent_run.run_result -> Oas.Raw_trace.run_validation option

val turn_mode_of_result : Keeper_agent_run.run_result -> turn_mode

val turn_mode_to_string : turn_mode -> string

val turn_mode_of_string : string -> turn_mode option

val turn_mode_of_json : Yojson.Safe.t -> turn_mode option

val work_kind_of_turn_mode : turn_mode -> string

val work_kind_of_json : Yojson.Safe.t -> string option

val accountability_evidence_refs :
  trace_id:string ->
  turn_number:int ->
  result:Keeper_agent_run.run_result ->
  validated_evidence:Oas.Raw_trace.run_validation option ->
  string list

val decision_channel_of_observation :
  Keeper_world_observation.world_observation -> string

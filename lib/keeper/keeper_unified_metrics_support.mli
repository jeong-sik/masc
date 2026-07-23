(** Shared helper layer for {!Keeper_unified_metrics}. *)

type turn_mode =
  | Tool_use
  | Text_response
  | Skip_text
  | Noop

type usage_trust = Keeper_usage_trust.t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

val observed_triggers_of_observation :
  ?meta:Keeper_meta_contract.keeper_meta ->
  Keeper_world_observation.world_observation ->
  string list

val observed_affordances_of_observation :
  ?meta:Keeper_meta_contract.keeper_meta ->
  Keeper_world_observation.world_observation ->
  string list

val classify_usage_trust :
  usage_reported:bool ->
  usage:Agent_sdk.Types.api_usage ->
  usage_trust

val estimate_usage_cost_usd :
  Agent_sdk.Types.api_usage ->
  float
(** Return the provider-reported value verbatim. Missing cost uses the numeric
    aggregate identity [0.0]; anomaly provenance is emitted separately. *)

val usage_trust_to_string : usage_trust -> string
val usage_trust_reasons : usage_trust -> string list
val usage_trust_json_fields : usage_trust -> (string * Yojson.Safe.t) list
val usage_trust_outcome_metric : string
val usage_anomaly_reason_metric : string

val record_usage_trust : keeper_name:string -> trust:usage_trust -> unit

val record_keeper_total_cost_usd :
  keeper_name:string -> total_cost_usd:float -> unit

val record_keeper_idle_seconds : keeper_name:string -> idle_seconds:int -> unit
val context_max_bucket : int -> string

val record_context_max_observation :
  keeper:string ->
  context_max:int ->
  unit

val turn_latency_bucket : int -> string
val long_turn_warn_threshold_ms_default : int
val long_turn_warn_threshold_ms : unit -> int
val record_turn_latency_bucket : keeper:string -> latency_ms:int -> unit

val record_turn_latency_by_model_bucket :
  keeper:string ->
  channel:string ->
  runtime_profile:string ->
  latency_ms:int ->
  unit

val has_substantive_tool_calls : string list -> bool
val is_noop_cycle : has_text:bool -> tools_used:string list -> bool

val visible_run_validation :
  Keeper_agent_run.run_result -> Agent_sdk.Raw_trace.run_validation option

val telemetry_reported_of_result : Keeper_agent_run.run_result -> bool
val coverage_reason_of_result : Keeper_agent_run.run_result -> string option
val coverage_stage_of_result : Keeper_agent_run.run_result -> string option
val coverage_stage_of_no_result_outcome : string -> string
val coverage_reason_of_no_result_outcome : string -> string
val validated_evidence_preview : Agent_sdk.Raw_trace.run_validation -> string

val accountability_evidence_refs :
  trace_id:string ->
  turn_number:int ->
  result:Keeper_agent_run.run_result ->
  validated_evidence:Agent_sdk.Raw_trace.run_validation option ->
  string list

val scheduled_autonomous_outcome_of_result :
  has_text:bool ->
  has_tool_calls:bool ->
  Keeper_meta_contract.proactive_cycle_outcome

val scheduled_autonomous_outcome_for_result :
  Keeper_agent_run.run_result -> Keeper_meta_contract.proactive_cycle_outcome

val turn_mode_to_string : turn_mode -> string
val turn_mode_of_string : string -> turn_mode option
val turn_mode_of_result : Keeper_agent_run.run_result -> turn_mode
val turn_mode_of_json : Yojson.Safe.t -> turn_mode option
val work_kind_of_turn_mode : turn_mode -> string
val work_kind_of_json : Yojson.Safe.t -> string option

val decision_channel_of_observation :
  Keeper_world_observation.world_observation ->
  Keeper_world_observation.keeper_cycle_channel

val is_scheduled_autonomous_cycle_of_observation :
  Keeper_world_observation.world_observation -> bool

val select_proactive_preview :
  previous:string ->
  has_text:bool ->
  is_visible_reply:bool ->
  has_substantive_tools:bool ->
  tool_names:string list ->
  response_text:string ->
  validated_evidence_preview:string option ->
  string
(** RFC-0232 scheduled-autonomous work preview, by precedence: visible model
    text (only when [is_visible_reply], so a no-output turn-limit observation
    is not shown as output) -> substantive tool calls ->
    validated evidence -> [previous]. Pure for unit testing. *)

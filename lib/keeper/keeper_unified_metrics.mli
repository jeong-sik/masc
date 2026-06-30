(** Keeper_unified_metrics — Observation helpers, decision records, and
    metrics update for the unified keeper cycle.

    Extracted from keeper_unified_turn.ml.

    @since 0.120.0 *)

(** Derive the trigger list from the observation. *)
val observed_triggers_of_observation :
  ?meta:Keeper_meta_contract.keeper_meta ->
  Keeper_world_observation.world_observation ->
  string list

(** Derive the affordance list from the observation. *)
val observed_affordances_of_observation :
  ?meta:Keeper_meta_contract.keeper_meta ->
  Keeper_world_observation.world_observation ->
  string list

type turn_mode =
  | Tool_use
  | Text_response
  | Skip_text
  | Noop

type usage_trust = Keeper_usage_trust.t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

val classify_usage_trust :
  usage_reported:bool ->
  usage:Agent_sdk.Types.api_usage ->
  context_max:int ->
  usage_trust
(** Classify usage counters without reconstructing concrete provider/model
    identity. *)

val usage_trust_is_trusted : usage_trust -> bool

val estimate_usage_cost_usd :
  Agent_sdk.Types.api_usage ->
  float
(** Return the OAS-reported turn cost. cost_usd is the provider's authoritative
    cost field and is accounted independently of token-count trust (token⊥cost).
    MASC does not estimate provider/model pricing locally; missing or
    non-positive cost remains [0.0]. *)

val usage_trust_to_string : usage_trust -> string

val usage_trust_reasons : usage_trust -> string list

val usage_trust_json_fields : usage_trust -> (string * Yojson.Safe.t) list

(** Canonical metric names for the per-turn usage-trust counters
    (#9959).  Exposed so tests can pin the names without hard-coding
    string literals.

    Labels:
    - [usage_trust_outcome_metric]: [("keeper", ...); ("outcome",
      "trusted" | "missing" | "untrusted")]
    - [usage_anomaly_reason_metric]: [("keeper", ...); ("reason", ...)]
      where [reason] is one of the strings [classify_usage_trust]
      attaches to [Usage_untrusted]. *)
val usage_trust_outcome_metric : string
val usage_anomaly_reason_metric : string

(** [record_usage_trust ~keeper_name ~trust] increments the outcome
    counter once and, for [Usage_untrusted] outcomes, also
    increments [usage_anomaly_reason_metric] per reason and logs a
    warn line.

    Intended for a single per-turn emit site — currently
    [update_metrics_from_result]. Other classify sites serialize
    [trust] into the JSONL ledger without bumping the counter so
    the counter rate equals the per-turn rate. *)
val record_usage_trust :
  keeper_name:string ->
  trust:usage_trust ->
  unit

val record_keeper_total_cost_usd :
  keeper_name:string ->
  total_cost_usd:float ->
  unit
(** Set [masc_keeper_total_cost_usd{keeper_name}] to the keeper runtime's
    accumulated trusted USD cost. *)

val context_max_bucket : int -> string
(** #9953: bucket a raw [context_max] integer into a bounded
    label vocabulary [zero | 64k | 128k | 200k | 256k | 1m |
    other].  Pure helper exposed so dashboards / runbooks can
    reference the same string mapping the metric uses. *)

val record_context_max_observation :
  keeper:string ->
  context_max:int ->
  unit
(** #9953: emit the
    [masc_keeper_context_max_observed_total
       {keeper, model_used, resolved_model_id, context_max_bucket}]
    counter for one turn.  The historical model labels are emitted as the
    neutral ["runtime"] lane. Intended to be called once per snapshot-write so
    the counter rate equals the per-turn rate. *)

(** {1 #9943: long-turn observer}

    [turn_latency_bucket ms] returns the bucket label for a turn that
    took [ms] milliseconds.  The vocabulary is bounded
    ([under_60s | 60-300s | 300-600s | 600-1200s | over_1200s]) so
    Otel_metric_store cardinality stays at [keeper × 5].

    [record_turn_latency_bucket] increments
    {!Keeper_metrics.(to_string TurnLatencyBucket)} on the matching
    bucket and emits a [Log.Keeper.warn] line when [latency_ms]
    crosses {!long_turn_warn_threshold_ms}.  Threshold reads
    [MASC_KEEPER_LONG_TURN_WARN_MS] (ms, default
    [long_turn_warn_threshold_ms_default = 600_000] = 10 min) on each
    call so operators can dial it without restart. *)
val turn_latency_bucket : int -> string

val long_turn_warn_threshold_ms_default : int

val long_turn_warn_threshold_ms : unit -> int

val record_turn_latency_bucket :
  keeper:string -> latency_ms:int -> unit

val record_turn_latency_by_model_bucket :
  keeper:string ->
  channel:string ->
  runtime_profile:string ->
  latency_ms:int ->
  unit


val update_metrics_from_result :
  Keeper_meta_contract.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  ?is_autonomous_turn:bool ->
  ?update_proactive_rt:bool ->
  ?context_max:int ->
  Keeper_agent_run.run_result ->
  Keeper_meta_contract.keeper_meta

val update_metrics_from_failure :
  Keeper_meta_contract.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  ?sdk_error:Agent_sdk.Error.sdk_error ->
  unit ->
  Keeper_meta_contract.keeper_meta

val append_metrics_snapshot :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  result:Keeper_agent_run.run_result ->
  latency_ms:int ->
  turn_cost:float ->
  turn_generation:int ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  snapshot_source:string ->
  context_ratio:float ->
  context_tokens:int ->
  context_max:int ->
  message_count:int ->
  compaction:Keeper_context_runtime.compaction_event ->
  handoff_json:Yojson.Safe.t option ->
  ?provider_timeout_plan_json:Yojson.Safe.t ->
  ?count_completed_turn:bool ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  unit ->
  unit

val append_decision_record :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell ->
  observation:Keeper_world_observation.world_observation ->
  latency_ms:int ->
  outcome:string ->
  ?degraded_retry_applied:bool ->
  ?degraded_retry_runtime:string ->
  ?fallback_reason:string ->
  ?turn_mode:turn_mode ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  ?result:Keeper_agent_run.run_result option ->
  ?error:string ->
  ?terminal_reason:Keeper_turn_terminal.t ->
  unit ->
  unit

val broadcast_lifecycle_events :
  name:string ->
  turn_generation:int ->
  compaction:Keeper_context_runtime.compaction_event ->
  handoff_json:Yojson.Safe.t option ->
  unit

val has_substantive_tool_calls : string list -> bool

val visible_run_validation :
  Keeper_agent_run.run_result -> Agent_sdk.Raw_trace.run_validation option

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
  validated_evidence:Agent_sdk.Raw_trace.run_validation option ->
  string list

val decision_channel_of_observation :
  Keeper_world_observation.world_observation ->
  Keeper_world_observation.keeper_cycle_channel

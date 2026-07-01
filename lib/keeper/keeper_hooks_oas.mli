(** Keeper Hooks (OAS bridge) — runtime telemetry, cost ledger, and
    pre-/post-tool hook factory.

    Bridges OAS [Agent_sdk.Hooks] callbacks with MASC's keeper accounting:
    records OAS-reported usage/cost with explicit unknowns, records
    Otel_metric_store metrics, and gates pre-tool execution via [Keeper_guards].
    Concrete provider/model identity remains OAS-owned; keeper-facing
    projections use neutral runtime lanes.  The [make_hooks] entry point
    wires every callback used by the keeper runtime turn loop. *)

(** {1 Static configuration} *)

val keeper_denied_tools : string list
(** Tool names that are always denied for keeper-bound execution
    regardless of runtime or persona policy. *)

(** usage_has_tokens / is_keeper_board_write_tool_name / current_keeper_model
    moved to Keeper_hooks_oas_types (intra-library file split, 2026-05-16). *)

(** {1 Tool-failure metrics} *)

val tool_use_failure_metric : string
(** Otel_metric_store metric name for tool-use failures. *)

val record_tool_use_failure : keeper_name:string -> tool_name:string -> unit
(** Increment [tool_use_failure_metric] for [(keeper, tool)]. *)

(** {1 Runtime-lane normalisation} *)

val resolve_after_turn_model :
  keeper_name:string -> response:Agent_sdk.Types.api_response -> string
(** Return the neutral runtime lane after a turn completes; emits quality
    metrics when OAS omits [response.model] or returns a selector alias,
    without exposing concrete model identity. *)

val record_response_content_quality_metric :
  keeper_name:string -> Agent_sdk.Types.api_response -> unit
(** Count after-turn responses that contain no visible assistant text and no
    tool progress.  Tool-use responses are progress, even when textual content
    is empty. *)

(** context_max_of_telemetry, redact_inference_telemetry_json,
    inference_telemetry_to_runtime_json moved to Keeper_hooks_oas_types
    (intra-library file split, 2026-05-16). Re-exported via include below. *)

(** {1 Usage-trust classification}

    Cost ledger trusts a usage record only when the provider, telemetry
    and counters are mutually consistent.  Anomalies (impossible token
    counts, missing fields) are demoted so downstream pricing and
    accounting can opt out of mis-reported numbers. *)

val classify_usage_trust :
  ?usage:Agent_sdk.Types.api_usage ->
  telemetry:Agent_sdk.Types.inference_telemetry option ->
  unit -> Keeper_usage_trust.t
(** Combine usage and OAS capability telemetry into a usage-trust verdict. *)

val record_usage_anomaly_metrics :
  keeper_name:string -> Keeper_usage_trust.t -> unit
(** Emit Otel_metric_store counters for each anomaly category in the verdict. *)

(** {1 Cost ledger}

    The cost_status ADT and its pure converters live in
    Keeper_hooks_oas_types (intra-library file split, 2026-05-16).
    Re-exported here so existing callers continue to use
    [Keeper_hooks_oas.cost_status] etc. unchanged. *)
include module type of Keeper_hooks_oas_types

(** {1 Tool execution summary}

    tool_execution_summary type + builder live in Keeper_hooks_oas_types
    (intra-library file split, 2026-05-16). Re-exported via include. *)

val record_keeper_tool_duration_metric :
  keeper_name:string -> tool_execution_summary -> unit
(** Emit the per-tool duration histogram for the summary. *)

(** {1 Throughput metrics} *)

val record_llm_tok_s_metrics :
  telemetry:Agent_sdk.Types.inference_telemetry option -> unit
(** Record provider-reported tokens-per-second when telemetry exposes it. *)

val record_llm_inference_latency_metric :
  telemetry:Agent_sdk.Types.inference_telemetry option -> unit
(** Record after-turn inference latency. [request_latency_ms <= 0] is counted
    by [masc_after_turn_telemetry_zero_latency_total] and floored to 1ms in
    [masc_llm_inference_duration_seconds] so a live hook does not leave the
    latency histogram blank. *)

val wall_tokens_per_second :
  usage_missing:bool ->
  output_tokens:int ->
  telemetry:Agent_sdk.Types.inference_telemetry option -> float option
(** Output tokens/sec computed from telemetry latency, subtracting
    [ttfrc_ms] when available so the fallback approximates decode
    throughput instead of first-token wait time. Returns [None] when usage
    / latency is missing. *)

(** {1 Cost emit source} *)

val cost_emit_source_metric : string
(** Otel_metric_store metric for the cost-emit source label. *)

val classify_cost_usd_source :
  usage_missing:bool ->
  usage_trusted:bool ->
  runtime_unmetered:bool -> cost_usd:float -> string
(** Classify the source of the emitted cost number for telemetry. *)

val record_cost_emit_source : String.t -> unit
(** Bump the [cost_emit_source_metric] for the given source label. *)

val cost_event_payload :
  agent_name:string ->
  task_id:string option ->
  input_tokens:int ->
  output_tokens:int ->
  cost_usd:float ->
  ?usage_missing:bool ->
  ?usage_trust:Keeper_usage_trust.t ->
  ?telemetry:Agent_sdk.Types.inference_telemetry -> ?model:string -> unit -> Yojson.Safe.t
(** Assemble the structured cost-ledger event without writing it. *)

val emit_cost_event :
  masc_root:string ->
  agent_name:string ->
  task_id:string option ->
  input_tokens:int ->
  output_tokens:int ->
  cost_usd:float ->
  ?usage_missing:bool ->
  ?usage_trust:Keeper_usage_trust.t ->
  ?telemetry:Agent_sdk.Types.inference_telemetry ->
  ?model:string -> unit -> unit
(** Append a structured cost-ledger event to [costs.jsonl]. *)

(** {1 Idle-loop policy} *)

val suggest_alternatives :
  allowed_tools:string list ->
  repeated_tools:string list -> max_suggestions:int -> string list
(** Suggest alternative tools to break a repetition loop. *)

val on_idle_decision_with_threshold :
  skip_at:int ->
  consecutive_idle_turns:int ->
  allowed_tools:string list ->
  tool_names:string list -> Agent_sdk.Hooks.hook_decision
(** Idle-handler with explicit [skip_at] threshold for testing. *)

val on_idle_decision :
  consecutive_idle_turns:int ->
  allowed_tools:string list ->
  tool_names:string list -> Agent_sdk.Hooks.hook_decision
(** Idle-handler with the production threshold. *)

val recent_tool_streak_count :
  ?within_sec:float -> tool_name:string -> Yojson.Safe.t list -> int
(** Count consecutive recent calls of [tool_name] in trajectory events. *)

(** PR-review / PR-work metric event types live in Keeper_hooks_oas_types
    (intra-library file split, 2026-05-16). Re-exported via include below. *)

(** {1 Hook factory} *)

val make_hooks :
  config:Workspace.config ->
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell ->
  generation:int ->
  ?max_cost_usd:float ->
  ?destructive_ops_policy:Destructive_ops_policy.t ->
  ?pre_tool_use_guard:(tool_name:string ->
                       input:Yojson.Safe.t -> string option) ->
  ?on_tool_executed:(tool_name:string ->
                     input:Yojson.Safe.t ->
                     output_text:string ->
                     success:bool ->
                     duration_ms:float -> provider:string ->
                     typed_outcome:Keeper_tool_outcome.t option -> unit) ->
  ?trajectory_acc:Trajectory.accumulator ->
  unit -> Agent_sdk.Hooks.hooks
(** Build the [Agent_sdk.Hooks.hooks] record used by the keeper turn loop:
    pre-tool gate, post-tool accounting, idle-detection, cost telemetry,
    and trajectory hooks all wired together. *)

val hook_introspection_json :
  ?max_cost_usd:float ->
  ?destructive_ops_policy:Destructive_ops_policy.t ->
  unit -> Yojson.Safe.t
(** JSON snapshot describing which hooks are active for the dashboard
    diagnostics surface. The destructive-pattern gate reflects whether
    [destructive_ops_policy] is enabled. *)

module For_testing : sig
  val tool_input_shape_for_log : Yojson.Safe.t -> string
  val tool_input_keys_for_log : Yojson.Safe.t -> string
  val tool_completion_records_watchdog_progress : string -> bool
end

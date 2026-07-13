(** Keeper Hooks (OAS bridge) — runtime telemetry, cost ledger, and
    pre-/post-tool observation factory.

    Bridges OAS [Agent_sdk.Hooks] callbacks with MASC's keeper accounting:
    records OAS-reported usage/cost with explicit unknowns, records
    Otel_metric_store metrics, and records tool timing without making an
    execution decision.
    Concrete provider/model identity remains OAS-owned; keeper-facing
    projections use neutral runtime lanes.  The [make_hooks] entry point
    wires every callback used by the keeper runtime turn loop. *)

(** usage_has_tokens / current_keeper_model
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
  unit -> Keeper_usage_trust.t
(** Validate objective non-negative usage-counter invariants. *)

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
  runtime_unmetered:bool -> cost_usd:float -> string
(** Classify the source of the emitted cost number for telemetry. *)

val record_cost_emit_source : String.t -> unit
(** Bump the [cost_emit_source_metric] for the given source label. *)

val cache_miss_input_tokens :
  input_tokens:int ->
  cache_creation_input_tokens:int -> cache_read_input_tokens:int -> int
(** Derive uncached input tokens from OAS usage counters, clamped at zero. *)

val cost_event_payload :
  agent_name:string ->
  task_id:string option ->
  input_tokens:int ->
  output_tokens:int ->
  cost_usd:float ->
  ?cache_creation_input_tokens:int ->
  ?cache_read_input_tokens:int ->
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
  ?cache_creation_input_tokens:int ->
  ?cache_read_input_tokens:int ->
  ?usage_missing:bool ->
  ?usage_trust:Keeper_usage_trust.t ->
  ?telemetry:Agent_sdk.Types.inference_telemetry ->
  ?model:string -> unit -> unit
(** Append a structured cost-ledger event to [costs.jsonl]. *)

(** PR-review / PR-work metric event types live in Keeper_hooks_oas_types
    (intra-library file split, 2026-05-16). Re-exported via include below. *)

(** {1 Hook factory} *)

val make_hooks :
  config:Workspace.config ->
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell ->
  generation:int ->
  ?on_tool_executed:(tool_name:string ->
                     input:Yojson.Safe.t ->
                     output_text:string ->
                     success:bool ->
                     duration_ms:float -> provider:string ->
                     typed_outcome:Keeper_tool_outcome.t option -> unit) ->
  ?trajectory_acc:Trajectory.accumulator ->
  unit -> Agent_sdk.Hooks.hooks
(** Build the [Agent_sdk.Hooks.hooks] record used by the keeper turn loop:
    passive pre-tool timing, post-tool accounting, idle detection, and
    trajectory hooks wired together. Cost remains part of post-turn
    observation. *)

val hook_introspection_json : unit -> Yojson.Safe.t
(** JSON snapshot describing which hooks are active for the dashboard
    diagnostics surface. *)

module For_testing : sig
  val tool_input_shape_for_log : Yojson.Safe.t -> string
  val tool_input_keys_for_log : Yojson.Safe.t -> string
end

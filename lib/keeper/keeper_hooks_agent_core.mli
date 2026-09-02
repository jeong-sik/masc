(** Keeper Hooks (AGENT_CORE bridge) — runtime telemetry, cost ledger, and
    pre-/post-tool observation factory.

    Bridges AGENT_CORE [Agent_core.Hooks] callbacks with MASC's keeper accounting:
    records AGENT_CORE-reported usage/cost with explicit unknowns, records
    Otel_metric_store metrics, and records tool timing without making an
    execution decision.
    Concrete provider/model identity remains AGENT_CORE-owned; keeper-facing
    projections use neutral runtime lanes.  The [make_hooks] entry point
    wires every callback used by the keeper runtime turn loop. *)

(** usage_has_tokens / current_keeper_model
    moved to Keeper_hooks_agent_core_types (intra-library file split, 2026-05-16). *)

(** {1 Tool-failure metrics} *)

val tool_use_failure_metric : string
(** Otel_metric_store metric name for tool-use failures. *)

val record_tool_use_failure : keeper_name:string -> tool_name:string -> unit
(** Increment [tool_use_failure_metric] for [(keeper, tool)]. *)

(** {1 Runtime-lane normalisation} *)

val resolve_after_turn_model :
  keeper_name:string -> response:Agent_core.Types.api_response -> string
(** Return the neutral runtime lane after a turn completes; emits quality
    metrics when AGENT_CORE omits [response.model] or returns a selector alias,
    without exposing concrete model identity. *)

val record_response_content_quality_metric :
  keeper_name:string -> Agent_core.Types.api_response -> unit
(** Count after-turn responses that contain no visible assistant text and no
    tool progress.  Tool-use responses are progress, even when textual content
    is empty. *)

(** context_max_of_telemetry, redact_inference_telemetry_json,
    inference_telemetry_to_runtime_json moved to Keeper_hooks_agent_core_types
    (intra-library file split, 2026-05-16). Re-exported via include below. *)

(** {1 Usage-trust classification}

    Cost ledger trusts a usage record only when the provider, telemetry
    and counters are mutually consistent.  Anomalies (impossible token
    counts, missing fields) are demoted so downstream pricing and
    accounting can opt out of mis-reported numbers. *)

val classify_usage_trust :
  ?usage:Agent_core.Types.api_usage ->
  unit -> Keeper_usage_trust.t
(** Validate objective non-negative usage-counter invariants.  A usage
    record without any token evidence (e.g. cost-only) is [Usage_missing],
    matching [usage_missing_of_usage], never [Usage_trusted]. *)

val record_usage_anomaly_metrics :
  keeper_name:string -> Keeper_usage_trust.t -> unit
(** Emit Otel_metric_store counters for each anomaly category in the verdict. *)

(** {1 Cost ledger}

    The cost_status ADT and its pure converters live in
    Keeper_hooks_agent_core_types (intra-library file split, 2026-05-16).
    Re-exported here so existing callers continue to use
    [Keeper_hooks_agent_core.cost_status] etc. unchanged. *)
include module type of Keeper_hooks_agent_core_types

(** {1 Tool execution summary}

    tool_execution_summary type + builder live in Keeper_hooks_agent_core_types
    (intra-library file split, 2026-05-16). Re-exported via include. *)

val record_keeper_tool_duration_metric :
  keeper_name:string -> tool_execution_summary -> unit
(** Emit the per-tool duration histogram for the summary. *)

(** {1 Throughput metrics} *)

val record_llm_tok_s_metrics :
  telemetry:Agent_core.Types.inference_telemetry option -> unit
(** Record provider-reported tokens-per-second when telemetry exposes it. *)

val record_llm_inference_latency_metric :
  telemetry:Agent_core.Types.inference_telemetry option -> unit
(** Record after-turn inference latency. [request_latency_ms <= 0] is counted
    by [masc_after_turn_telemetry_zero_latency_total] and floored to 1ms in
    [masc_llm_inference_duration_seconds] so a live hook does not leave the
    latency histogram blank. *)

val wall_tokens_per_second :
  usage_missing:bool ->
  output_tokens:int ->
  telemetry:Agent_core.Types.inference_telemetry option -> float option
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
(** Derive uncached input tokens from AGENT_CORE usage counters, clamped at zero. *)

val cost_event_payload :
  agent_name:string ->
  task_id:string option ->
  trace_id:string ->
  keeper_turn_id:int ->
  agent_core_turn_ordinal:int ->
  model:string ->
  input_tokens:int ->
  output_tokens:int ->
  cost_usd:float ->
  ?usage_projection:Cost_ledger.usage_projection ->
  ?cache_creation_input_tokens:int ->
  ?cache_read_input_tokens:int ->
  ?usage_missing:bool ->
  ?usage_trust:Keeper_usage_trust.t ->
  ?telemetry:Agent_core.Types.inference_telemetry -> unit -> Yojson.Safe.t
(** Assemble the structured cost-ledger event without writing it. *)

val emit_cost_event :
  masc_root:string ->
  agent_name:string ->
  task_id:string option ->
  trace_id:string ->
  keeper_turn_id:int ->
  agent_core_turn_ordinal:int ->
  model:string ->
  input_tokens:int ->
  output_tokens:int ->
  cost_usd:float ->
  ?usage_projection:Cost_ledger.usage_projection ->
  ?cache_creation_input_tokens:int ->
  ?cache_read_input_tokens:int ->
  ?usage_missing:bool ->
  ?usage_trust:Keeper_usage_trust.t ->
  ?telemetry:Agent_core.Types.inference_telemetry -> unit -> unit
(** Append a structured cost-ledger event to [costs/YYYY-MM/DD.jsonl]. *)

val broadcast_resolved_turn_complete :
  keeper_name:string ->
  turn:int ->
  tool_calls_made:int ->
  total_turns:int ->
  usage_resolution:Keeper_usage_resolution.t ->
  unit


(** PR-review / PR-work metric event types live in Keeper_hooks_agent_core_types
    (intra-library file split, 2026-05-16). Re-exported via include below. *)

(** {1 Hook factory} *)

type tool_stream_observation =
  | Runtime_attempt_started of
      { runtime_id : string
      ; lane_attempt_index : int
      ; checkpoint_owner : Runtime_execution.checkpoint_owner
      }
      (** The turn driver resolved this exact lane candidate and is about to
          dispatch it. This is the attempt boundary for streamed occurrences;
          assignment ids and provider message ids are not substitutes. *)
  | Turn_collected of
      { turn : int
      ; tool_source_map : Agent_core.Hooks.admitted_tool_source_map
      }
      (** Agent Core retained the exact pre-admission mapping before tools run. *)
  | Turn_closed_without_sources of { turn : int }
      (** A producer without a pre-admission sidecar completed the turn. Its
          streamed calls stay delivery-only; no ordinal or provider-id guess
          is allowed to attach a canonical execution. *)

val make_hooks :
  config:Workspace.config ->
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell ->
  trace_id:string ->
  keeper_turn_id:int ->
  on_after_turn_ordinal:(int -> unit) ->
  ?on_tool_stream_observation:(tool_stream_observation -> unit) ->
  ?on_after_turn_response:(response:Agent_core.Types.api_response -> unit) ->
  ?on_tool_executed:(tool_name:string ->
                     input:Yojson.Safe.t ->
                     output_text:string ->
                     success:bool ->
                     duration_ms:float -> provider:string ->
                     typed_outcome:Keeper_tool_outcome.t option -> unit) ->
  ?tool_result_commit_required:(unit -> bool) ->
  ?on_tool_result_ready:(tool_call_id:string -> turn:int -> planned_index:int -> execution_id:Ids.Execution_id.t -> unit) ->
  ?trajectory_acc:Trajectory.accumulator ->
  unit -> Agent_core.Hooks.hooks
(** Build the [Agent_core.Hooks.hooks] record used by the keeper turn loop:
    passive pre-tool timing, post-tool accounting, idle detection, and
    trajectory hooks wired together. [on_tool_stream_observation] reports an
    exact Agent Core admission mapping or an unavailable-sidecar turn close
    without conflating those states.
    [on_after_turn_response] observes each provider turn's assistant
    response right after the turn ordinal is recorded. [on_tool_result_ready]
    runs only after the exact tool-call log
    row is synchronously committed and carries the provider call id, Agent
    Core occurrence coordinates, and canonical execution id written to that
    row. [tool_result_commit_required] makes log-commit failure strict only for
    the active producer contract; official-client delivery-only attempts remain
    best effort. Cost remains part of post-turn observation. *)

val hook_introspection_json : unit -> Yojson.Safe.t
(** JSON snapshot describing which hooks are active for the dashboard
    diagnostics surface. *)

module For_testing : sig
  val tool_input_shape_for_log : Yojson.Safe.t -> string
  val tool_input_keys_for_log : Yojson.Safe.t -> string
  val cost_usd_json : float option -> Yojson.Safe.t
  (** Exact projection used by the turn-complete SSE payload. *)
  val usage_missing_of_usage : Agent_core.Types.api_usage option -> bool
  (** Hook usage-evidence decision delegated to {!usage_has_tokens}. *)
end

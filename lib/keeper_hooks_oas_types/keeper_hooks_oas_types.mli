(** Keeper_hooks_oas_types — pure type definitions and helpers extracted
    from Keeper_hooks_oas (2762 LoC godfile).

    Holds the cost_status verdict ADT + its pure label/reason converters.
    State-touching keeper_hooks_oas operations remain in Keeper_hooks_oas.
    Re-included by Keeper_hooks_oas so existing callers continue to use
    [Keeper_hooks_oas.cost_status] etc. unchanged. *)

(** Otel_metric_store + JSON label-key string constants used across
    keeper_hooks_oas.ml call sites. *)
val label_keeper : string
val label_callback : string
val label_tool : string
val label_source : string
val label_alias : string
val label_surface : string
val label_shape : string
val label_model : string
val label_provider : string
val label_provider_kind : string
val label_status : string
val label_site : string
val label_reason : string
val label_outcome : string
val label_stop_reason : string
val label_keeper_name : string
val label_channel : string

(** JSON field-key string constants used across keeper_hooks_oas.ml. *)
val key_agent : string
val key_task_id : string
val key_input_tokens : string
val key_output_tokens : string
val key_cost_usd : string
val key_cost_status : string
val key_cost_status_reason : string
val key_cost_usd_source : string
val key_usage_missing : string
val key_timestamp : string
val key_reasoning_tokens : string
val key_cache_n : string
val key_prompt_per_second : string
val key_provider_tokens_per_second : string
val key_hw_decode_tokens_per_second : string
val key_peak_memory_gb : string
val key_request_latency_ms : string
val key_tokens_per_second : string
val key_status : string
val key_reason : string
val key_provider : string
val key_model : string
val key_source : string
val key_type : string
val key_turn : string
val key_model_used : string
val key_tool_calls_made : string
val key_total_turns : string
val key_scope : string
val key_slots : string
val key_ts_unix : string
val key_name : string
val key_generation : string
val key_active : string
val key_via : string
val key_route_via : string
val key_metric_event : string
val key_agent_name : string
val key_tool_name : string
val key_tool_call_count : string
val key_tools_used : string
val key_duration_ms : string
val key_channel : string
val key_error : string
val key_ts : string

(** Callback name labels used as Otel_metric_store + log identifiers. *)
val callback_label_after_turn_sse_broadcast : string
val callback_label_post_tool_log_write : string
val callback_label_on_tool_executed : string
val callback_label_on_error : string
val callback_label_on_tool_error : string

type cost_status =
  | Cost_reported         (** Cost value was reported by OAS. *)
  | Cost_known_free       (** Runtime is structurally unmetered. *)
  | Cost_no_tokens        (** Usage carried zero tokens and no positive cost. *)
  | Cost_usage_missing    (** OAS returned no usage record. *)
  | Cost_runtime_unknown  (** Runtime owner could not be classified. *)
  | Cost_oas_cost_unreported
      (** OAS returned token usage but did not report cost. *)
(** Per-event cost-ledger verdict. *)

val cost_status_to_string : cost_status -> string
(** Stable wire string for [cost_status]. *)

val cost_status_reason : cost_status -> string
(** Human-readable explanation for an operator log. *)

val cost_status_for_event :
  runtime_unknown:bool ->
  runtime_unmetered:bool ->
  usage_missing:bool ->
  input_tokens:int -> output_tokens:int -> cost_usd:float -> cost_status
(** Pure decision: which [cost_status] applies given the inputs above? *)

(** Internal: cost-status wire labels exposed for keeper_hooks_oas's
    [classify_cost_usd_source] which composes a string verdict separately
    from [cost_status_to_string]. *)
val cost_label_usage_missing : string
val cost_label_oas_cost_unreported : string

val redact_inference_telemetry_json : Yojson.Safe.t -> Yojson.Safe.t
(** Redact provider/model identity fields from OAS inference telemetry while
    preserving non-identifying runtime counters and timings. *)

val inference_telemetry_to_runtime_json :
  Agent_sdk.Types.inference_telemetry -> Yojson.Safe.t
(** JSON projection for keeper-facing persistence/API surfaces.  Concrete
    provider/model identity is collapsed before leaving the OAS boundary. *)

val context_max_of_telemetry :
  Agent_sdk.Types.inference_telemetry option -> int
(** Provider-reported context window max, or [0] when telemetry omits it. *)

type thinking_log_summary =
  { thinking_present : bool
  ; thinking_blocks : int
  ; thinking_chars : int
  ; redacted_thinking_blocks : int
  ; thinking_kind : string
  }
(** Redacted metadata for provider thinking blocks.  [thinking_chars] counts
    only non-redacted [Thinking.content] bytes; raw content is never included
    in this summary. *)

val summarize_thinking_blocks :
  Agent_sdk.Types.content_block list -> thinking_log_summary
(** Summarize thinking block presence for logs/metrics without exposing raw
    thinking content. *)

val runtime_lane_label : string
(** The neutral runtime lane label used by keeper telemetry where concrete
    provider/model identity should not surface (consumed by many call sites
    in keeper_hooks_oas.ml). *)

type tool_execution_summary = {
  tool_name : string;
  provider : string;
  outcome : string;
  duration_ms : float;
}
(** Per-tool-call record persisted in the keeper's trajectory. *)

val tool_execution_summary :
  tool_name:string ->
  model:string -> success:bool -> duration_ms:float -> tool_execution_summary
(** Build a [tool_execution_summary] from raw turn fields. *)

val usage_has_tokens : Agent_sdk.Types.api_usage -> bool
(** [true] when the usage record carries a non-zero token count. *)

(** [true] when the tool writes to the shared MASC board; subject to
    extra guard rules. *)

val current_keeper_model : 'a -> string
(** Neutral runtime lane used for keeper-facing tool-call telemetry.
    Concrete provider/model identity is OAS-owned. *)

(** Internal: stop-reason string labels exposed for keeper_hooks_oas.ml
    consumers that emit them across multiple call sites. *)
val stop_reason_label_end_turn : string
val stop_reason_label_tool_use : string
val stop_reason_label_max_tokens : string
val stop_reason_label_stop_sequence : string
val stop_reason_label_unknown : string

val stop_reason_to_label : Agent_sdk.Types.stop_reason -> string
(** Canonical telemetry/metric label for an OAS stop reason.  Delegates to
    OAS so [keeper_hooks_oas] finish-reason fields and response metrics share
    the provider/model stop-reason SSOT. *)

val zero_usage : Agent_sdk.Types.api_usage
(** Internal: zero-token api_usage marker used by classify_usage_trust
    when telemetry is missing. *)

val telemetry_has_canonical_model_id :
  Agent_sdk.Types.inference_telemetry option -> bool
(** Internal: true when telemetry carries a non-empty canonical_model_id. *)

val canonical_model_id_of_telemetry :
  Agent_sdk.Types.inference_telemetry option -> string option
(** Internal: returns the canonical model id when telemetry carries a
    non-empty one, [None] otherwise. *)

val is_runtime_selector_alias : string -> bool
(** Internal: true when the trimmed model leaf equals ["auto"]. *)

val ms_per_second : float
(** Internal: 1000.0 unit-conversion constant for duration_ms. *)

val cost_source_unmetered_provider : string
val cost_source_computed : string
(** Internal: cost-source labels used by classify_cost_usd_source. *)

val oas_reported_cost : Agent_sdk.Types.api_usage -> float
(** Internal: preserve a reported cost verbatim; missing uses [0.0]. *)

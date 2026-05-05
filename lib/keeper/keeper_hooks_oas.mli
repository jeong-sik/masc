(** Keeper Hooks (OAS bridge) — provider classification, cost ledger,
    and pre-/post-tool hook factory.

    Bridges OAS [Agent_sdk.Hooks] callbacks with MASC's keeper accounting:
    classifies the provider/model that produced each turn, derives a
    trustworthy USD cost (with explicit unknowns), records Prometheus
    metrics, and gates pre-tool execution via [Keeper_guards].  The
    [make_hooks] entry point wires every callback used by the keeper
    runtime turn loop. *)

(** {1 Static configuration} *)

val keeper_denied_tools : string list
(** Tool names that are always denied for keeper-bound execution
    regardless of cascade or persona policy. *)

(** {1 Provider classification} *)

val provider_of_model :
  ?provider_kind:Llm_provider.Provider_config.provider_kind ->
  string -> string
(** Map a model label (e.g. ["claude-3-5-sonnet"]) to a provider id
    (e.g. ["anthropic"]).  Optional [provider_kind] supplies a hint
    when the model label is ambiguous. *)

val provider_kind_of_telemetry :
  Agent_sdk.Types.inference_telemetry option ->
  Llm_provider.Provider_kind.t option
(** Extract the provider kind from inference telemetry, when present. *)

val provider_of_model_with_telemetry :
  model:string ->
  telemetry:Agent_sdk.Types.inference_telemetry option -> string
(** [provider_of_model] but consults telemetry first so a model alias
    (e.g. ["auto"]) resolves to the actual provider used for the turn. *)

val structurally_unmetered_provider : string -> bool
(** [true] for providers whose tokens are not metered by upstream
    (e.g. local ollama).  Used to short-circuit the cost ledger. *)

val usage_has_tokens : Agent_sdk.Types.api_usage -> bool
(** [true] when the usage record carries a non-zero token count. *)

(** {1 Pre-tool gate integration} *)

val is_keeper_board_write_tool_name : string -> bool
(** [true] when the tool writes to the shared MASC board; subject to
    extra guard rules. *)

val current_keeper_model : Keeper_types.keeper_meta -> string
(** The model id the keeper is configured to use right now. *)

val render_pre_tool_gate_output :
  Keeper_guards.gate_decision_event -> string
(** Render the gate decision as a tool-use response body for the LLM. *)

val pre_tool_gate_error :
  Keeper_guards.gate_decision_event -> string
(** Render the gate decision as a structured error message for logs. *)

val record_pre_tool_gate_attempt :
  meta_ref:Keeper_types.keeper_meta ref ->
  tool_call_count_ref:int ref ->
  ?trajectory_acc:Trajectory.accumulator ->
  Keeper_guards.gate_decision_event -> unit
(** Update keeper-local counters and trajectory accumulator on every
    gate-checked tool attempt (allowed or denied). *)

(** {1 Tool-failure metrics} *)

val tool_use_failure_metric : string
(** Prometheus metric name for tool-use failures. *)

val record_tool_use_failure : keeper_name:string -> tool_name:string -> unit
(** Increment [tool_use_failure_metric] for [(keeper, tool)]. *)

(** {1 Model-id canonicalisation} *)

val empty_response_model_metric : string
(** Prometheus metric for responses whose model is missing. *)

val alias_response_model_metric : string
(** Prometheus metric for responses whose model is still an alias
    (e.g. ["auto"]). *)

val unknown_model_sentinel : string
(** Sentinel string for unknown model ids in metric/log labels. *)

val zero_usage : Agent_sdk.Types.api_usage
(** All-zero [api_usage] used as a default. *)

val canonical_model_id_of_telemetry :
  model:string -> Agent_sdk.Types.inference_telemetry option -> string
(** Resolve [model] to its canonical id using telemetry when available,
    falling back to [model] when not. *)

val known_provider_model_id_of_label : string -> string option
(** Lookup the canonical model id for a known provider label, or
    [None] when the label is not in the registry. *)

val model_id_leaf : string -> string
(** Strip the provider prefix from a fully qualified model id. *)

val is_auto_model_label : string -> bool
(** [true] when the label is an [auto]-style alias rather than a
    concrete model id. *)

val canonical_model_id_opt :
  Agent_sdk.Types.inference_telemetry option -> string option
(** Canonical model id from telemetry alone, [None] when telemetry is
    missing or carries no model info. *)

val resolve_after_turn_model :
  keeper_name:string -> response:Agent_sdk.Types.api_response -> string
(** Best-effort model resolution after a turn completes; emits anomaly
    metrics when the response model is missing or still aliased. *)

val context_max_of_telemetry :
  Agent_sdk.Types.inference_telemetry option -> int
(** Provider-reported context window max, or [0] when telemetry omits it. *)

(** {1 Usage-trust classification}

    Cost ledger trusts a usage record only when the provider, telemetry
    and counters are mutually consistent.  Anomalies (impossible token
    counts, missing fields) are demoted so downstream pricing and
    accounting can opt out of mis-reported numbers. *)

val classify_usage_trust :
  ?usage:Agent_sdk.Types.api_usage ->
  model:string ->
  telemetry:Agent_sdk.Types.inference_telemetry option ->
  unit -> Keeper_usage_trust.t
(** Combine usage / model / telemetry into a usage-trust verdict. *)

val record_usage_anomaly_metrics :
  keeper_name:string -> model:string -> Keeper_usage_trust.t -> unit
(** Emit Prometheus counters for each anomaly category in the verdict. *)

val estimate_usage_cost_usd :
  model:string -> Agent_sdk.Types.api_usage -> float
(** Estimate USD cost from token counts using the static pricing
    catalogue.  Returns [0.] when the model is unpriced. *)

(** {1 Cost ledger} *)

type cost_status =
  | Cost_reported_or_estimated
      (** Cost trusted: either reported by the provider or estimated from
          tokens against the pricing catalogue. *)
  | Cost_known_free       (** Provider runs locally / structurally unmetered. *)
  | Cost_no_tokens        (** Usage carried zero tokens and no positive cost. *)
  | Cost_usage_missing    (** Provider returned no usage record. *)
  | Cost_usage_untrusted  (** Usage failed [classify_usage_trust]. *)
  | Cost_provider_unknown (** Provider could not be classified. *)
  | Cost_unpriced_model   (** Model has no entry in the pricing catalogue. *)
(** Per-event cost-ledger verdict. *)

val cost_status_to_string : cost_status -> string
(** Stable wire string for [cost_status]. *)

val cost_status_reason : cost_status -> string
(** Human-readable explanation for an operator log. *)

val pricing_model_for_ledger :
  model:string ->
  telemetry:Agent_sdk.Types.inference_telemetry option -> string
(** Model id used for the pricing lookup (not necessarily the
    response's model — telemetry-canonicalised). *)

val model_resolution_source_for_ledger :
  model:string -> pricing_model:string -> string
(** Diagnostic label describing how [pricing_model] was derived from
    [model] (e.g. ["telemetry"], ["alias_resolved"], ["fallback"]). *)

val pricing_catalog_status : pricing_model:string -> string
(** Catalogue lookup status for the resolved pricing model
    (["hit_paid"] / ["hit_free"] / ["miss"]).  Unresolved aliases
    such as ["auto"] remain misses so missing canonical telemetry is
    visible in the ledger. *)

val cost_status_for_event :
  provider:string ->
  pricing_model:string ->
  usage_missing:bool ->
  usage_trusted:bool ->
  input_tokens:int -> output_tokens:int -> cost_usd:float -> cost_status
(** Pure decision: which [cost_status] applies given the inputs above? *)

val cost_usd_for_usage :
  ?provider_kind:Llm_provider.Provider_config.provider_kind ->
  model:string -> Agent_sdk.Types.api_usage -> float
(** Public cost calculator combining provider classification and
    pricing catalogue. *)

(** {1 Tool execution summary} *)

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

val record_keeper_tool_duration_metric :
  keeper_name:string -> tool_execution_summary -> unit
(** Emit the per-tool duration histogram for the summary. *)

(** {1 Throughput metrics} *)

val record_llm_tok_s_metrics :
  model:string ->
  telemetry:Agent_sdk.Types.inference_telemetry option -> unit
(** Record provider-reported tokens-per-second when telemetry exposes it. *)

val wall_tokens_per_second :
  usage_missing:bool ->
  output_tokens:int ->
  telemetry:Agent_sdk.Types.inference_telemetry option -> float option
(** Wall-clock tokens/sec computed from telemetry latency, or [None]
    when usage / latency is missing. *)

(** {1 Cost emit source} *)

val cost_emit_source_metric : string
(** Prometheus metric for the cost-emit source label. *)

val classify_cost_usd_source :
  usage_missing:bool ->
  usage_trusted:bool ->
  provider:string -> model:string -> cost_usd:float -> string
(** Classify the source of the emitted cost number for telemetry. *)

val record_cost_emit_source : String.t -> unit
(** Bump the [cost_emit_source_metric] for the given source label. *)

val cost_event_payload :
  agent_name:string ->
  task_id:string option ->
  model:string ->
  input_tokens:int ->
  output_tokens:int ->
  cost_usd:float ->
  ?usage_missing:bool ->
  ?usage_trust:Keeper_usage_trust.t ->
  ?telemetry:Agent_sdk.Types.inference_telemetry -> unit -> Yojson.Safe.t
(** Assemble the structured cost-ledger event without writing it. *)

val emit_cost_event :
  masc_root:string ->
  agent_name:string ->
  task_id:string option ->
  model:string ->
  input_tokens:int ->
  output_tokens:int ->
  cost_usd:float ->
  ?usage_missing:bool ->
  ?usage_trust:Keeper_usage_trust.t ->
  ?telemetry:Agent_sdk.Types.inference_telemetry -> unit -> unit
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

type pr_review_action_metric_event = {
  action : string;
  pr_number : int option;
  comment_id : int option;
  success : bool;
}
(** Parsed PR-review action telemetry derived from keeper tool I/O. *)

type pr_work_action_metric_event = {
  work_action : string;
  work_source : string;
  command : string option;
  success : bool;
}
(** Parsed PR create/push/commit/add telemetry derived from keeper tool I/O. *)

(** {1 Hook factory} *)

val make_hooks :
  config:Coord.config ->
  meta_ref:Keeper_types.keeper_meta ref ->
  generation:int ->
  ?max_cost_usd:float ->
  ?destructive_check:bool ->
  ?pre_tool_use_guard:(tool_name:string ->
                       input:Yojson.Safe.t -> string option) ->
  ?on_tool_executed:(tool_name:string ->
                     input:Yojson.Safe.t ->
                     output_text:string ->
                     success:bool ->
                     duration_ms:float -> provider:string -> unit) ->
  ?trajectory_acc:Trajectory.accumulator ->
  ?discover_work_nudge:(unit -> string option) ->
  ?passive_loop_nudge:(unit -> string option) ->
  unit -> Agent_sdk.Hooks.hooks
(** Build the [Agent_sdk.Hooks.hooks] record used by the keeper turn loop:
    pre-tool gate, post-tool accounting, idle-detection, cost guard,
    and trajectory hooks all wired together. *)

val hook_introspection_json :
  ?max_cost_usd:float -> ?destructive_check:bool -> unit -> Yojson.Safe.t
(** JSON snapshot describing which hooks are active for the dashboard
    diagnostics surface. *)

module For_testing : sig
  val pr_review_action_metric_event_of_tool_io :
    tool_name:string ->
    input:Yojson.Safe.t ->
    output_text:string ->
    transport_success:bool ->
    pr_review_action_metric_event option

  val pr_work_action_metric_events_of_tool_io :
    tool_name:string ->
    input:Yojson.Safe.t ->
    output_text:string ->
    transport_success:bool ->
    pr_work_action_metric_event list
end

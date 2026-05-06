(** Keeper single-turn orchestration via OAS Agent.run().

    Loads checkpoint, composes system prompt and dynamic context via
    [build_turn_prompt], applies tool disclosure (progressive filtering),
    then delegates to [Oas_worker.run_named].

    Internal details — tool selection heuristics, BM25 prefiltering,
    prompt metrics construction, Korean keyword tables — are hidden
    behind this interface. *)

(** {1 Types} *)

(** Prompt segments passed to [run_turn] via [build_turn_prompt] callback. *)
type turn_prompt =
  { system_prompt : string
  ; dynamic_context : string
  }

(** Byte-level metrics for a single prompt segment. *)
type prompt_segment_metrics =
  { bytes : int
  ; estimated_tokens : int
  ; fingerprint : string option
  }

(** Aggregated prompt metrics for a keeper turn.
    [estimated_cacheable_tokens] tracks the system prompt portion only
    (OAS prompt caching is enabled via [cache_system_prompt:true]). *)
type prompt_metrics =
  { fingerprint : string
  ; estimated_total_tokens : int
  ; estimated_cacheable_tokens : int
  ; system_prompt_segment : prompt_segment_metrics
  ; dynamic_context_segment : prompt_segment_metrics
  ; user_message_segment : prompt_segment_metrics
  }

(** Estimated CTX composition for the effective keeper input.
    [segments] contains attributed token buckets; when estimator coverage is
    incomplete, [unattributed] is added to keep the stacked total aligned with
    the actual provider-reported [input_tokens]. *)
type ctx_composition_metrics =
  { actual_input_tokens : int option
  ; display_total_tokens : int
  ; estimated_known_tokens : int
  ; segments : (string * prompt_segment_metrics) list
  }

type tool_requirement = Keeper_agent_tool_surface.tool_requirement

type tool_surface_metrics =
  { turn_lane : string
  ; tool_surface_class : string
  ; tool_requirement : tool_requirement
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  ; required_tool_names : string list
  ; missing_required_tool_names : string list
  ; config_root : string
  ; cascade_config_path : string option
  ; gemini_mcp_disabled : bool
  ; approval_mode_effective : string option
  ; approval_mode_derived : bool
  }

type tool_call_detail =
  { tool_name : string
  ; provider : string
  ; outcome : string
  ; latency_ms : float
  ; route_evidence : Yojson.Safe.t option
  }

val tool_call_detail_to_json : tool_call_detail -> Yojson.Safe.t

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; model_used : string
  ; prompt_metrics : prompt_metrics
  ; ctx_composition : ctx_composition_metrics
  ; cascade_observation : Oas_worker.cascade_observation option
  ; turn_count : int
  ; tool_calls_made : int
  ; usage : Agent_sdk.Types.api_usage
  ; usage_reported : bool
  ; tools_used : string list
  ; tool_calls : tool_call_detail list
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; proof : Agent_sdk.Cdal_proof.t option
  ; trace_ref : Agent_sdk.Raw_trace.run_ref option
  ; run_validation : Agent_sdk.Raw_trace.run_validation option
  ; stop_reason : Oas_worker.stop_reason
  ; inference_telemetry : Agent_sdk.Types.inference_telemetry option
  ; tool_surface : tool_surface_metrics
  }

(** Result of pre-dispatch resume checkpoint hygiene.

    [resume_checkpoint] is the only checkpoint passed to OAS resume.  It is
    derived from the sanitized MASC working context, optionally after
    pre-dispatch compaction, so run_turn does not reload a separate raw
    checkpoint immediately before dispatch. *)
type pre_dispatch_checkpoint_hygiene_result =
  { context : Keeper_types.working_context
  ; resume_checkpoint : Agent_sdk.Checkpoint.t option
  ; compacted : bool
  ; applied : bool
  ; meaningful_reduction : bool
  ; before_tokens : int
  ; after_tokens : int
  ; trigger : string option
  ; decision : Keeper_compact_policy.compaction_decision
  ; save_error : string option
  }

val prepare_resume_checkpoint_for_dispatch :
     meta:Keeper_types.keeper_meta
  -> now_ts:float
  -> loaded_checkpoint_present:bool
  -> save_checkpoint:
       (Keeper_types.working_context -> (Agent_sdk.Checkpoint.t, string) result)
  -> Keeper_types.working_context
  -> pre_dispatch_checkpoint_hygiene_result

val should_require_tools_for_initial_turn :
  max_turns:int -> turn_affordances:string list -> bool

val preferred_tool_choice_for_required_turn :
     has_current_task:bool
  -> turn_affordances:string list
  -> allowed_tool_names:string list
  -> Agent_sdk.Types.tool_choice

(** Filtered variant of [turn_affordances_require_tool_gate] (in
    {!Keeper_agent_tool_surface}): only counts an affordance when at
    least one tool capable of satisfying it appears in
    [allowed_tool_names].  Used at the [Require_tool_use] contract gate
    so keepers without the relevant action tools (e.g. a [social]
    preset facing unclaimed tasks) aren't forced into unwinnable
    contract violations. *)
val turn_affordances_require_tool_gate_with_allowed :
  allowed_tool_names:string list -> string list -> bool

(** Canonical model label for MASC status/metrics surfaces.
    Prefers the final cascade attempt label when available, then the
    selected/primary configured cascade label, and finally falls back to the
    raw provider-reported [model_used]. *)
val surface_model_used : run_result -> string

(** Resolved concrete model id for MASC status/metrics surfaces.

    Unlike {!surface_model_used}, this always returns the resolved provider
    model id (e.g. ["claude-opus-4-6"]) regardless of whether a cascade
    label (e.g. ["claude_code:auto"]) was present. Falls back to the raw
    [model_used] when no cascade observation is available, and to the empty
    string when neither source has a value.

    Rationale (#9953): the [claude_code:auto] label resolves to different
    concrete variants per turn (sonnet / opus / haiku) and each variant has
    a different [max_context_tokens]. Recording only the label hides the
    drift source — analysts cannot correlate ["context_max"] with the
    actual resolved variant. Emitting both [model_used] (label) and
    [resolved_model_id] (concrete id) in the metric line makes the
    drift observable. *)
val surface_resolved_model_id : run_result -> string

(** {1 Telemetry serialisation} *)

val build_prompt_metrics :
     system_prompt:string
  -> dynamic_context:string
  -> user_message:string
  -> prompt_metrics

(** [actual_input_tokens] is the LLM-reported input token count and is
    only known after a provider response. Pre-call sites (prompt build)
    must pass [None]; post-response sites pass [Some n]. *)
val build_ctx_composition_metrics :
     system_prompt:string
  -> dynamic_context:string
  -> memory_context:string
  -> temporal_context:string
  -> user_message:string
  -> history_messages:Agent_sdk.Types.message list
  -> actual_input_tokens:int option
  -> ctx_composition_metrics

val prompt_metrics_to_json : prompt_metrics -> Yojson.Safe.t
val ctx_composition_to_json : ctx_composition_metrics -> Yojson.Safe.t

(** {1 Inference tuning} *)

(** Adaptive thinking budget: raises budget when tool errors, long context,
    or retry conditions are detected. Pure function — safe to call from
    tests without Eio context. *)
val adaptive_thinking_budget :
     enabled:bool
  -> is_retry:bool
  -> last_tool_results:Agent_sdk.Types.tool_result list
  -> user_message:string
  -> dynamic_context:string
  -> current_budget:int option
  -> intent:Keeper_turn_intent.t option
  -> int option

(** {1 Turn execution} *)

(** Run a single keeper turn.

    @param config Coord configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
    @param build_turn_prompt Callback: receives the base keeper system prompt
           and checkpoint message history, returns the final turn system prompt
    @param user_message The user's message to the keeper
    @param cascade_name Typed runtime cascade profile name for model selection
    @param world_observation Structured keeper world snapshot used by
           required-tool contract checks. When omitted, the contract gate
           does not infer world state from prompt text.
    @param provider_filter Optional provider restriction
    @param generation Current generation counter
    @param max_turns Maximum agent turns (default from env config)
    @param max_idle_turns Maximum consecutive idle turns before stop
    @param history_user_source Source label for user messages in history
    @param history_assistant_source Source label for assistant messages in history
    @param guardrails Optional OAS guardrails for tool safety gates
    @param temperature MODEL temperature override
    @param max_tokens Maximum output tokens override
    @param max_cost_usd Maximum cost per turn in USD
    @param on_event Optional event callback
    @param trajectory_acc Optional trajectory accumulator for recording
    @param tool_overlay Optional mutable tool overlay for dynamic tools
    @param priority Optional priority for scheduling
    @param is_retry When [true], replays current user message without persisting
    @param shared_context Optional shared OAS context for cross-turn state
    @param event_bus Optional MASC event bus *)
val run_turn :
     config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> base_dir:string
  -> max_context:int
  -> build_turn_prompt:
       (   base_system_prompt:string
        -> messages:Agent_sdk.Types.message list
        -> turn_prompt)
  -> user_message:string
  -> cascade_name:Keeper_cascade_profile.runtime_name
  -> ?world_observation:Keeper_world_observation.world_observation
  -> ?turn_affordances:string list
  -> ?provider_filter:string list
  -> generation:int
  -> ?max_turns:int
  -> ?max_idle_turns:int
  -> ?history_user_source:string
  -> ?history_assistant_source:string
  -> ?guardrails:Agent_sdk.Guardrails.t
  -> ?temperature:float
  -> ?max_tokens:int
  -> ?oas_timeout_s:float
  -> ?max_cost_usd:float
  -> ?on_event:(Agent_sdk.Types.sse_event -> unit)
  -> ?trajectory_acc:Trajectory.accumulator
  -> ?tool_overlay:Agent_sdk.Tool_op.t ref
  -> ?priority:Llm_provider.Request_priority.t
  -> ?degraded_retry_applied:bool
  -> ?degraded_retry_cascade:string
  -> ?fallback_reason:string
  -> ?cascade_rotation_attempts:
       Keeper_execution_receipt.cascade_rotation_attempt list
  -> ?is_retry:bool
  -> ?shared_context:Agent_sdk.Context.t
  -> ?event_bus:Agent_sdk.Event_bus.t
  -> unit
  -> (run_result, Agent_sdk.Error.sdk_error) result

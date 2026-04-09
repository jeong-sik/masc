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

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; model_used : string
  ; prompt_metrics : prompt_metrics
  ; cascade_observation : Oas_worker.cascade_observation option
  ; turn_count : int
  ; tool_calls_made : int
  ; usage : Agent_sdk.Types.api_usage
  ; tools_used : string list
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; proof : Agent_sdk.Cdal_proof.t option
  ; run_validation : Agent_sdk.Raw_trace.run_validation option
  ; stop_reason : Oas_worker.stop_reason
  ; inference_telemetry : Agent_sdk.Types.inference_telemetry option
  }

(** {1 Telemetry serialisation} *)

val build_prompt_metrics :
     system_prompt:string
  -> dynamic_context:string
  -> user_message:string
  -> prompt_metrics

val prompt_metrics_to_json : prompt_metrics -> Yojson.Safe.t

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
  -> int option

(** {1 Turn execution} *)

(** Run a single keeper turn.

    @param config Room configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
    @param build_turn_prompt Callback: receives the base keeper system prompt
           and checkpoint message history, returns the final turn system prompt
    @param user_message The user's message to the keeper
    @param cascade_name Cascade profile name for model selection
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
     config:Room.config
  -> meta:Keeper_types.keeper_meta
  -> base_dir:string
  -> max_context:int
  -> build_turn_prompt:
       (   base_system_prompt:string
        -> messages:Agent_sdk.Types.message list
        -> turn_prompt)
  -> user_message:string
  -> cascade_name:string
  -> ?provider_filter:string list
  -> generation:int
  -> ?max_turns:int
  -> ?max_idle_turns:int
  -> ?history_user_source:string
  -> ?history_assistant_source:string
  -> ?guardrails:Agent_sdk.Guardrails.t
  -> ?temperature:float
  -> ?max_tokens:int
  -> ?max_cost_usd:float
  -> ?on_event:(Oas.Types.sse_event -> unit)
  -> ?trajectory_acc:Trajectory.accumulator
  -> ?tool_overlay:Agent_sdk.Tool_op.t ref
  -> ?priority:Llm_provider.Request_priority.t
  -> ?is_retry:bool
  -> ?shared_context:Agent_sdk.Context.t
  -> ?event_bus:Agent_sdk.Event_bus.t
  -> unit
  -> (run_result, Oas.Error.sdk_error) result

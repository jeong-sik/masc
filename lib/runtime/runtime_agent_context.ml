(** Runtime_agent_context — Shared config and agent assembly helpers.

    This module owns the shared [config] surface plus the pure/defaulted
    preparation logic used by both [build] and [resume_from_checkpoint].
    [Runtime_agent] remains the public facade and still performs the
    approval wiring and final [build_safe] / [Agent.resume] calls. *)

let default_max_turns = Agent_sdk.Types.default_config.max_turns

type stop_reason =
  | Completed
  | TurnBudgetExhausted of
      { turns_used : int
      ; limit : int
      }
  | MutationBoundaryReached of
      { turns_used : int
      ; tool_name : string option
      }
  | Yielded_to_chat_waiting of { turns_used : int }
    (* The autonomous lane's OAS run stopped at a turn boundary because a
       dashboard/connector chat request was parked on the keeper's turn slot.
       Progress is checkpointed and the keeper resumes on the next cycle — the
       same disposition as [MutationBoundaryReached], but a distinct reason so
       receipts do not conflate an on-demand yield with a budget/mutation stop. *)

type config =
  { name : string
  ; provider_cfg : Llm_provider.Provider_config.t
  ; provider : Agent_sdk.Provider.config
  ; model_id : string
  ; priority : Llm_provider.Request_priority.t option
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; max_turns : int
  ; max_idle_turns : int
  ; stream_idle_timeout_s : float option
  ; max_execution_time_s : float option
    (** Wall-clock ceiling for one [Agent_sdk.Agent.run] / [run_stream]
          call. When [Some s] AND a clock is available at the call site,
          agent_sdk's [with_optional_timeout] returns
          [Error (Api (Retry.Timeout {...}))] after [s] seconds — the
          runtime FSM already maps [Retry.Timeout] to a fallback signal,
          so this is the canonical knob to bound a hung [run_stream]
          when a provider closes the connection without [end_turn].
          Default [None] preserves the historical behaviour
          (block indefinitely on stream-parser hang). *)
  ; body_timeout_s : float option
    (** Total HTTP body-consumption ceiling for non-streaming OAS completion
        paths. Streaming paths deliberately ignore this knob so active long
        streams are not killed by total duration; streaming liveness is
        owned by [stream_idle_timeout_s] plus attempt observation. Non-HTTP
        transports ignore it. *)
  ; max_tokens : int
  ; temperature : float
  ; hooks : Agent_sdk.Hooks.hooks option
  ; context_reducer : Agent_sdk.Context_reducer.t option
  ; guardrails : Agent_sdk.Guardrails.t option
  ; event_bus : Agent_sdk.Event_bus.t option
  ; checkpoint_dir : string option
  ; session_id : string option
  ; description : string option
  ; initial_messages : Agent_sdk.Types.message list
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; transport : Masc_grpc_transport.t
  ; allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; compact_ratio : float option
  ; context_window_tokens : int option
  ; oas_auto_context_overflow_retry : bool
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; approval : Agent_sdk.Hooks.approval_callback option
  ; exit_condition : (int -> bool) option
  ; exit_condition_result : (int -> stop_reason * string option) option
  ; summarizer : (Agent_sdk.Types.message list -> string) option
    (** Custom summarizer for OAS [Budget_strategy.reduce_for_budget]
          Emergency-phase compaction. Defaults to OAS's extractive
          default. Keeper workers inject [Keeper_summarizer.keeper_summarizer]
          to scrub [STATE] blocks before the 100-char truncation. *)
  ; execution_idle_timeout_s : float option
    (** Per-run inactivity deadline forwarded to OAS
        [Builder.with_execution_idle_timeout]. Resets on each unit of
        progress (streamed token or completed turn) and fires only on
        genuine silence, surfacing [Error.AgentExecutionIdleTimeout].
        Unlike [max_execution_time_s] (total wall-clock), this never
        cancels a run that is still producing output.
        @since 0.201.0 OAS *)
  ; thinking_budget : int option
    (** Token budget for extended thinking, forwarded to OAS
        [Builder.with_thinking_budget]. Only meaningful when
        [enable_thinking = Some true]. *)
  ; top_p : float option
    (** Nucleus sampling probability forwarded to OAS [Builder.with_top_p].
        [None] leaves the provider/model default intact. *)
  ; top_k : int option
    (** Top-k sampling limit forwarded to OAS [Builder.with_top_k].
        [None] leaves the provider/model default intact. *)
  ; min_p : float option
    (** Minimum probability threshold for nucleus sampling, forwarded
        to OAS [Builder.with_min_p]. [None] leaves the provider default;
        [Some 0.0] is a no-op and some providers reject the field. *)
  ; on_run_complete : (bool -> unit) option
    (** Callback invoked when an OAS run finishes (success or failure).
        Forwarded to [Builder.with_on_run_complete]. Useful for emitting
        telemetry, flushing OTel spans, or finalizing receipts. *)
  ; disclosure_level : Agent_sdk.Tool.disclosure_level option
    (** Tool schema disclosure level forwarded to
        [Builder.with_disclosure_level]. Controls whether full schemas
        or minimal name+description indices are sent to the LLM.
        [None] preserves the default (Full_schema). *)
  ; disclosure_resolver
      : (Agent_sdk.Types.tool_result list -> Agent_sdk.Tool.disclosure_level option) option
    (** Per-turn resolver that adapts disclosure based on previous tool
        results. Forwarded to [Builder.with_disclosure_resolver].
        Overrides [disclosure_level] for the current turn when [Some]
        is returned. *)
  ; tool_selector : Agent_sdk.Tool_selector.strategy option
    (** Tool selection strategy for large tool catalogs, forwarded to
        [Builder.with_tool_selector]. When tool count exceeds ~15,
        narrows candidates per turn before sending schemas to the LLM. *)
  ; checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option
    (** Caller-owned turn-boundary checkpoint sink, forwarded to
        [Builder.with_checkpoint_sink]. Allows consumers to persist
        checkpoints at OAS turn boundaries without the full
        checkpoint_dir filesystem path. *)
  }

let default_config
      ~name
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~system_prompt
      ~tools
  : config
  =
  let provider =
    Agent_sdk.Provider.config_of_provider_config provider_cfg
    |> Runtime_wire_overlay.apply ~provider_cfg
  in
  { name
  ; provider_cfg
  ; provider
  ; model_id = provider_cfg.model_id
  ; priority = None
  ; system_prompt
  ; tools
  ; runtime_mcp_policy = None
  ; max_turns = default_max_turns
  ; max_idle_turns = 3
  ; stream_idle_timeout_s = None
  ; max_execution_time_s = None
  ; body_timeout_s = None
  ; max_tokens = Runtime_provider_defaults.agent_default_max_tokens
  ; temperature = Runtime_provider_defaults.agent_default_temperature
  ; hooks = None
  ; context_reducer = None
  ; guardrails = None
  ; event_bus = None
  ; checkpoint_dir = None
  ; session_id = None
  ; description = None
  ; initial_messages = []
  ; raw_trace = None
  ; trace_link = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; transport = Masc_grpc_transport.from_env ()
  ; allowed_paths = []
  ; checkpoint_sidecar = None
  ; cache_system_prompt = false
  ; yield_on_tool = false
  ; compact_ratio = None
  ; context_window_tokens = None
  ; oas_auto_context_overflow_retry = true
  ; context_injector = None
  ; context = None
  ; approval = None
  ; exit_condition = None
  ; exit_condition_result = None
  ; summarizer = None
  ; execution_idle_timeout_s = None
  ; thinking_budget = None
  ; top_p = provider_cfg.top_p
  ; top_k = provider_cfg.top_k
  ; min_p = provider_cfg.min_p
  ; on_run_complete = None
  ; disclosure_level = None
  ; disclosure_resolver = None
  ; tool_selector = None
  ; checkpoint_sink = None
  }
;;

let oas_tracer_ref = Atomic.make Agent_sdk.Tracing.null
let set_oas_tracer tracer = Atomic.set oas_tracer_ref tracer

let guardrails_of_config (config : config) =
  let tool_names = List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) config.tools in
  match config.guardrails with
  | Some g -> g
  | None ->
    { Agent_sdk.Guardrails.default with
      tool_filter =
        (if tool_names <> []
         then Agent_sdk.Guardrails.AllowList tool_names
         else Agent_sdk.Guardrails.AllowAll)
    }
;;

let builder_without_approval
      ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
      ~(config : config)
      ?transport
      ()
  : Agent_sdk.Builder.t
  =
  let guardrails = guardrails_of_config config in
  let builder =
    Agent_sdk.Builder.create ~net ~model:config.model_id
    |> Agent_sdk.Builder.with_name config.name
    |> Agent_sdk.Builder.with_system_prompt config.system_prompt
    |> Agent_sdk.Builder.with_max_tokens config.max_tokens
    |> Agent_sdk.Builder.with_max_turns config.max_turns
    |> Agent_sdk.Builder.with_max_idle_turns config.max_idle_turns
    |> Agent_sdk.Builder.with_temperature config.temperature
    |> Agent_sdk.Builder.with_provider config.provider
    |> Agent_sdk.Builder.with_tools config.tools
    |> Agent_sdk.Builder.with_guardrails guardrails
    |> Agent_sdk.Builder.with_missing_approval_callback_policy
         Agent_sdk.Hooks.Reject_without_callback
  in
  let builder =
    match config.stream_idle_timeout_s with
    | Some timeout_s -> Agent_sdk.Builder.with_stream_idle_timeout timeout_s builder
    | None -> builder
  in
  let builder =
    match config.max_execution_time_s with
    | Some s -> Agent_sdk.Builder.with_max_execution_time s builder
    | None -> builder
  in
  let builder =
    match config.body_timeout_s with
    | Some s -> Agent_sdk.Builder.with_body_timeout s builder
    | None -> builder
  in
  let builder =
    match config.hooks with
    | Some h -> Agent_sdk.Builder.with_hooks h builder
    | None -> builder
  in
  let builder =
    match config.context_reducer with
    | Some r -> Agent_sdk.Builder.with_context_reducer r builder
    | None -> builder
  in
  let builder =
    match config.description with
    | Some d -> Agent_sdk.Builder.with_description d builder
    | None -> builder
  in
  let builder =
    match config.raw_trace with
    | Some raw_trace -> Agent_sdk.Builder.with_raw_trace raw_trace builder
    | None -> builder
  in
  let builder =
    match config.enable_thinking with
    | Some enabled -> Agent_sdk.Builder.with_enable_thinking enabled builder
    | None -> builder
  in
  let builder =
    match config.preserve_thinking with
    | Some preserve -> Agent_sdk.Builder.with_preserve_thinking preserve builder
    | None -> builder
  in
  let builder =
    match config.priority with
    | Some priority -> Agent_sdk.Builder.with_priority priority builder
    | None -> builder
  in
  let builder =
    match config.runtime_mcp_policy with
    | Some policy -> Agent_sdk.Builder.with_runtime_mcp_policy policy builder
    | None -> builder
  in
  let builder =
    if config.cache_system_prompt
    then Agent_sdk.Builder.with_cache_system_prompt true builder
    else builder
  in
  let builder =
    if config.yield_on_tool
    then Agent_sdk.Builder.with_yield_on_tool true builder
    else builder
  in
  let builder =
    if config.allowed_paths <> []
    then Agent_sdk.Builder.with_allowed_paths config.allowed_paths builder
    else builder
  in
  let builder =
    if config.initial_messages <> []
    then Agent_sdk.Builder.with_initial_messages config.initial_messages builder
    else builder
  in
  let builder =
    match config.context_window_tokens with
    | Some window ->
      let compact_ratio =
        Option.value
          ~default:Agent_sdk.Types.default_context_compact_ratio
          config.compact_ratio
      in
      Agent_sdk.Builder.with_context_thresholds
        ~compact_ratio
        ~context_window_tokens:window
        builder
    | None ->
      (match config.compact_ratio with
       | Some ratio -> Agent_sdk.Builder.with_context_thresholds ~compact_ratio:ratio builder
       | None -> builder)
  in
  let builder =
    Agent_sdk.Builder.with_auto_context_overflow_retry
      config.oas_auto_context_overflow_retry
      builder
  in
  let builder =
    match config.context_injector with
    | Some injector -> Agent_sdk.Builder.with_context_injector injector builder
    | None -> builder
  in
  let builder =
    match config.context with
    | Some ctx -> Agent_sdk.Builder.with_context ctx builder
    | None -> builder
  in
  let builder =
    match config.exit_condition with
    | Some cond -> Agent_sdk.Builder.with_exit_condition cond builder
    | None -> builder
  in
  let builder =
    match config.summarizer with
    | Some s -> Agent_sdk.Builder.with_summarizer s builder
    | None -> builder
  in
  let builder =
    match config.execution_idle_timeout_s with
    | Some s -> Agent_sdk.Builder.with_execution_idle_timeout s builder
    | None -> builder
  in
  let builder =
    match config.thinking_budget with
    | Some budget -> Agent_sdk.Builder.with_thinking_budget budget builder
    | None -> builder
  in
  let builder =
    match config.top_p with
    | Some top_p -> Agent_sdk.Builder.with_top_p top_p builder
    | None -> builder
  in
  let builder =
    match config.top_k with
    | Some top_k -> Agent_sdk.Builder.with_top_k top_k builder
    | None -> builder
  in
  let builder =
    match config.min_p with
    | Some min_p -> Agent_sdk.Builder.with_min_p min_p builder
    | None -> builder
  in
  let builder =
    match config.event_bus with
    | Some bus -> Agent_sdk.Builder.with_event_bus bus builder
    | None -> builder
  in
  let builder =
    match config.on_run_complete with
    | Some cb -> Agent_sdk.Builder.with_on_run_complete cb builder
    | None -> builder
  in
  let builder =
    match config.disclosure_level with
    | Some level -> Agent_sdk.Builder.with_disclosure_level level builder
    | None -> builder
  in
  let builder =
    match config.disclosure_resolver with
    | Some resolver -> Agent_sdk.Builder.with_disclosure_resolver resolver builder
    | None -> builder
  in
  let builder =
    match config.tool_selector with
    | Some strategy -> Agent_sdk.Builder.with_tool_selector strategy builder
    | None -> builder
  in
  let builder =
    match config.checkpoint_sink with
    | Some sink -> Agent_sdk.Builder.with_checkpoint_sink sink builder
    | None -> builder
  in
  let builder =
    Agent_sdk.Builder.with_tracer (Atomic.get oas_tracer_ref) builder
  in
  match transport with
  | Some transport -> Agent_sdk.Builder.with_transport transport builder
  | None -> builder
;;

type prepared_resume =
  { patched_checkpoint : Agent_sdk.Checkpoint.t
  ; agent_config : Agent_sdk.Types.agent_config
  ; options : Agent_sdk.Agent.options
  }

let prepare_resume ~(config : config) ~(checkpoint : Agent_sdk.Checkpoint.t)
  : prepared_resume
  =

  let max_turns_for_resume =
    if config.max_turns = 0 then 0 else checkpoint.turn_count + config.max_turns
  in
  let patched_checkpoint =
    { checkpoint with
      Agent_sdk.Checkpoint.model = config.model_id
    ; system_prompt = Some config.system_prompt
    ; temperature = Some config.temperature
    ; top_p = config.top_p
    ; top_k = config.top_k
    ; min_p = config.min_p
    ; enable_thinking = config.enable_thinking
    ; preserve_thinking = config.preserve_thinking
    ; thinking_budget = config.thinking_budget
    ; cache_system_prompt = config.cache_system_prompt
    ; response_format = config.provider_cfg.response_format
      (* MASC owns the structured-output contract via [config.provider_cfg].
         A checkpoint may carry a stale [response_format] from a previous run
         (e.g., prompt-tier fallback or an older native schema).  If we resumed
         with [JsonMode] while the current base config carries a native schema,
         [Runtime_agent.request_runtime_fields_on_base_config] would treat the
         stale request as an explicit opinion and clear the contract.  Patch the
         checkpoint so the resume path observes the same contract as a fresh
         build. *)
    }
  in
  let agent_config : Agent_sdk.Types.agent_config =
    { Agent_sdk.Types.default_config with
      name = config.name
    ; model = config.model_id
    ; system_prompt = Some config.system_prompt
    ; max_tokens = Some config.max_tokens
    ; max_turns = max_turns_for_resume
    ; temperature = Some config.temperature
    ; top_p = config.top_p
    ; top_k = config.top_k
    ; min_p = config.min_p
    ; enable_thinking = config.enable_thinking
    ; preserve_thinking = config.preserve_thinking
    ; thinking_budget = config.thinking_budget
    ; cache_system_prompt = config.cache_system_prompt
    ; yield_on_tool = config.yield_on_tool
    ; context_compact_ratio = config.compact_ratio
    ; priority = config.priority
    ; exit_condition = config.exit_condition
    }
  in
  let options : Agent_sdk.Agent.options =
    { Agent_sdk.Agent.default_options with
      provider = Some config.provider
    ; hooks = Option.value ~default:Agent_sdk.Hooks.empty config.hooks
    ; max_idle_turns = config.max_idle_turns
    ; stream_idle_timeout_s = config.stream_idle_timeout_s
    ; max_execution_time_s = config.max_execution_time_s
    ; body_timeout_s = config.body_timeout_s
    ; execution_idle_timeout_s = config.execution_idle_timeout_s
    ; guardrails = guardrails_of_config config
    ; context_reducer = config.context_reducer
    ; context_injector = config.context_injector
    ; event_bus = config.event_bus
    ; raw_trace = config.raw_trace
    ; allowed_paths = config.allowed_paths
    ; description = config.description
    ; approval = config.approval
    ; missing_approval_callback_policy =
        Agent_sdk.Hooks.Reject_without_callback
    ; runtime_mcp_policy = config.runtime_mcp_policy
    ; summarizer = config.summarizer
    ; priority = config.priority
    ; on_run_complete = config.on_run_complete
    ; disclosure_level = config.disclosure_level
    ; disclosure_resolver = config.disclosure_resolver
    ; tool_selector = config.tool_selector
    }
  in
  { patched_checkpoint; agent_config; options }
;;

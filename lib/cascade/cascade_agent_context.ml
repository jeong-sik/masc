(** Cascade_agent_context — Shared config and agent assembly helpers.

    This module owns the shared [config] surface plus the pure/defaulted
    preparation logic used by both [build] and [resume_from_checkpoint].
    [Cascade_runner] remains the public facade and still performs the
    approval wiring and final [build_safe] / [Agent.resume] calls. *)

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
          cascade FSM already maps [Retry.Timeout] to a fallback signal,
          so this is the canonical knob to bound a hung [run_stream]
          when a provider closes the connection without [end_turn].
          Default [None] preserves the historical behaviour
          (block indefinitely on stream-parser hang). *)
  ; max_tokens : int
  ; max_input_tokens : int option
  ; max_cost_usd : float option
  ; temperature : float
  ; hooks : Agent_sdk.Hooks.hooks option
  ; context_reducer : Agent_sdk.Context_reducer.t option
  ; guardrails : Agent_sdk.Guardrails.t option
  ; event_bus : Agent_sdk.Event_bus.t option
  ; checkpoint_dir : string option
  ; session_id : string option
  ; description : string option
  ; memory : Agent_sdk.Memory.t option
  ; initial_messages : Agent_sdk.Types.message list
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; tool_retry_policy : Agent_sdk.Tool_retry_policy.t option
  ; required_tool_satisfaction : Agent_sdk.Completion_contract.required_tool_satisfaction
  ; contract : Masc_mcp_cdal_runtime.Risk_contract.t option
  ; enable_thinking : bool option
  ; transport : Masc_grpc_transport.t
  ; allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; compact_ratio : float option
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; slot_id : int option
  ; approval : Agent_sdk.Hooks.approval_callback option
  ; exit_condition : (int -> bool) option
  ; exit_condition_result : (int -> stop_reason * string option) option
  ; summarizer : (Agent_sdk.Types.message list -> string) option
  ; cli_transport_overrides : Cascade_transport.cli_transport_overrides option
    (** Custom summarizer for OAS [Budget_strategy.reduce_for_budget]
          Emergency-phase compaction. Defaults to OAS's extractive
          default. Keeper workers inject [Keeper_summarizer.keeper_summarizer]
          to scrub [STATE] blocks before the 100-char truncation. *)
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
    |> Provider_adapter.apply_wire_overlay ~provider_cfg
  in
  { name
  ; provider_cfg
  ; provider
  ; model_id = provider_cfg.model_id
  ; priority = None
  ; system_prompt
  ; tools
  ; runtime_mcp_policy = None
  ; max_turns = 20
  ; max_idle_turns = 3
  ; stream_idle_timeout_s = None
  ; max_execution_time_s = None
  ; max_tokens = Cascade_legacy_runner.default_max_tokens
  ; max_input_tokens = None
  ; max_cost_usd = None
  ; temperature = Cascade_legacy_runner.default_temperature
  ; hooks = None
  ; context_reducer = None
  ; guardrails = None
  ; event_bus = None
  ; checkpoint_dir = None
  ; session_id = None
  ; description = None
  ; memory = None
  ; initial_messages = []
  ; raw_trace = None
  ; tool_retry_policy = None
  ; required_tool_satisfaction = Agent_sdk.Completion_contract.any_tool_call_satisfies
  ; contract = None
  ; enable_thinking = None
  ; transport = Masc_grpc_transport.from_env ()
  ; allowed_paths = []
  ; checkpoint_sidecar = None
  ; cache_system_prompt = false
  ; yield_on_tool = false
  ; compact_ratio = None
  ; context_injector = None
  ; context = None
  ; slot_id = None
  ; approval = None
  ; exit_condition = None
  ; exit_condition_result = None
  ; summarizer = None
  ; cli_transport_overrides = None
  }
;;

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
    if config.tools <> []
    then Agent_sdk.Builder.with_tool_choice Agent_sdk.Types.Auto builder
    else builder
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
    match config.memory with
    | Some m -> Agent_sdk.Builder.with_memory m builder
    | None -> builder
  in
  let builder =
    match config.raw_trace with
    | Some raw_trace -> Agent_sdk.Builder.with_raw_trace raw_trace builder
    | None -> builder
  in
  let builder =
    match config.tool_retry_policy with
    | Some policy -> Agent_sdk.Builder.with_tool_retry_policy policy builder
    | None -> builder
  in
  let builder =
    Agent_sdk.Builder.with_required_tool_satisfaction
      config.required_tool_satisfaction
      builder
  in
  let builder =
    match config.enable_thinking with
    | Some enabled -> Agent_sdk.Builder.with_enable_thinking enabled builder
    | None -> builder
  in
  let builder =
    match config.priority with
    | Some priority -> Agent_sdk.Builder.with_priority priority builder
    | None -> builder
  in
  let builder =
    match config.max_cost_usd with
    | Some usd -> Agent_sdk.Builder.with_max_cost_usd usd builder
    | None -> builder
  in
  let builder =
    match config.max_input_tokens with
    | Some tokens -> Agent_sdk.Builder.with_max_input_tokens tokens builder
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
    match config.compact_ratio with
    | Some ratio -> Agent_sdk.Builder.with_context_thresholds ~compact_ratio:ratio builder
    | None -> builder
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
    match config.slot_id with
    | Some id -> Agent_sdk.Builder.with_slot_id id builder
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
  let effective_max_turns = checkpoint.turn_count + config.max_turns in
  let effective_max_cost_usd =
    match config.max_cost_usd with
    | Some budget -> Some (checkpoint.usage.estimated_cost_usd +. budget)
    | None -> None
  in
  let patched_checkpoint =
    { checkpoint with
      Agent_sdk.Checkpoint.model = config.model_id
    ; system_prompt = Some config.system_prompt
    ; temperature = Some config.temperature
    ; enable_thinking = config.enable_thinking
    ; cache_system_prompt = config.cache_system_prompt
    ; max_input_tokens = config.max_input_tokens
    ; max_total_tokens = None
    }
  in
  let agent_config : Agent_sdk.Types.agent_config =
    { Agent_sdk.Types.default_config with
      name = config.name
    ; model = config.model_id
    ; system_prompt = Some config.system_prompt
    ; max_tokens = Some config.max_tokens
    ; max_turns = effective_max_turns
    ; temperature = Some config.temperature
    ; enable_thinking = config.enable_thinking
    ; cache_system_prompt = config.cache_system_prompt
    ; max_input_tokens = config.max_input_tokens
    ; max_cost_usd = effective_max_cost_usd
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
    ; guardrails = guardrails_of_config config
    ; context_reducer = config.context_reducer
    ; context_injector = config.context_injector
    ; event_bus = config.event_bus
    ; memory = config.memory
    ; raw_trace = config.raw_trace
    ; tool_retry_policy = config.tool_retry_policy
    ; required_tool_satisfaction = config.required_tool_satisfaction
    ; allowed_paths = config.allowed_paths
    ; description = config.description
    ; approval = config.approval
    ; slot_id = config.slot_id
    ; runtime_mcp_policy = config.runtime_mcp_policy
    ; summarizer = config.summarizer
    ; priority = config.priority
    }
  in
  { patched_checkpoint; agent_config; options }
;;

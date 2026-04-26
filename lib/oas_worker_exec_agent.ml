(** Oas_worker_exec_agent — Shared config and agent assembly helpers.

    This module owns the shared [config] surface plus the pure/defaulted
    preparation logic used by both [build] and [resume_from_checkpoint].
    [Oas_worker_exec] remains the public facade and still performs the
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
  ; provider : Oas.Provider.config
  ; model_id : string
  ; priority : Llm_provider.Request_priority.t option
  ; system_prompt : string
  ; tools : Oas.Tool.t list
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; max_turns : int
  ; max_idle_turns : int
  ; stream_idle_timeout_s : float option
  ; max_tokens : int
  ; max_input_tokens : int option
  ; max_cost_usd : float option
  ; temperature : float
  ; hooks : Oas.Hooks.hooks option
  ; context_reducer : Oas.Context_reducer.t option
  ; guardrails : Oas.Guardrails.t option
  ; event_bus : Oas.Event_bus.t option
  ; checkpoint_dir : string option
  ; session_id : string option
  ; description : string option
  ; memory : Oas.Memory.t option
  ; initial_messages : Oas.Types.message list
  ; raw_trace : Oas.Raw_trace.t option
  ; tool_retry_policy : Oas.Tool_retry_policy.t option
  ; required_tool_satisfaction : Oas.Completion_contract.required_tool_satisfaction
  ; contract : Oas.Risk_contract.t option
  ; enable_thinking : bool option
  ; transport : Masc_grpc_transport.t
  ; allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; compact_ratio : float option
  ; context_injector : Oas.Hooks.context_injector option
  ; context : Oas.Context.t option
  ; slot_id : int option
  ; approval : Oas.Hooks.approval_callback option
  ; exit_condition : (int -> bool) option
  ; exit_condition_result : (int -> stop_reason * string option) option
  ; summarizer : (Oas.Types.message list -> string) option
  ; cli_transport_overrides : Oas_worker_exec_transport.cli_transport_overrides option
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
    let provider = Oas.Provider.config_of_provider_config provider_cfg in
    match provider_cfg.kind, provider.provider with
    | Llm_provider.Provider_config.OpenAI_compat, Oas.Provider.Local { base_url }
      when not
             (String.equal
                provider_cfg.request_path
                Masc_network_defaults.openai_chat_completions_path) ->
      let auth_header =
        if String.trim provider_cfg.api_key = "" then None else Some "Authorization"
      in
      let static_token =
        match String.trim provider_cfg.api_key with
        | "" -> None
        | token -> Some token
      in
      { provider with
        provider =
          Oas.Provider.OpenAICompat
            { base_url; auth_header; path = provider_cfg.request_path; static_token }
      }
    | _ -> provider
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
  ; max_tokens = Oas_worker_cascade.default_max_tokens
  ; max_input_tokens = None
  ; max_cost_usd = None
  ; temperature = Oas_worker_cascade.default_temperature
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
  ; required_tool_satisfaction = Oas.Completion_contract.any_tool_call_satisfies
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
  let tool_names = List.map (fun (t : Oas.Tool.t) -> t.schema.name) config.tools in
  match config.guardrails with
  | Some g -> g
  | None ->
    { Oas.Guardrails.default with
      tool_filter =
        (if tool_names <> []
         then Oas.Guardrails.AllowList tool_names
         else Oas.Guardrails.AllowAll)
    }
;;

let builder_without_approval
      ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
      ~(config : config)
      ?transport
      ()
  : Oas.Builder.t
  =
  let guardrails = guardrails_of_config config in
  let builder =
    Oas.Builder.create ~net ~model:config.model_id
    |> Oas.Builder.with_name config.name
    |> Oas.Builder.with_system_prompt config.system_prompt
    |> Oas.Builder.with_max_tokens config.max_tokens
    |> Oas.Builder.with_max_turns config.max_turns
    |> Oas.Builder.with_max_idle_turns config.max_idle_turns
    |> Oas.Builder.with_temperature config.temperature
    |> Oas.Builder.with_provider config.provider
    |> Oas.Builder.with_tools config.tools
    |> Oas.Builder.with_guardrails guardrails
  in
  let builder =
    match config.stream_idle_timeout_s with
    | Some timeout_s -> Oas.Builder.with_stream_idle_timeout timeout_s builder
    | None -> builder
  in
  let builder =
    if config.tools <> []
    then Oas.Builder.with_tool_choice Oas.Types.Auto builder
    else builder
  in
  let builder =
    match config.hooks with
    | Some h -> Oas.Builder.with_hooks h builder
    | None -> builder
  in
  let builder =
    match config.context_reducer with
    | Some r -> Oas.Builder.with_context_reducer r builder
    | None -> builder
  in
  let builder =
    match config.description with
    | Some d -> Oas.Builder.with_description d builder
    | None -> builder
  in
  let builder =
    match config.memory with
    | Some m -> Oas.Builder.with_memory m builder
    | None -> builder
  in
  let builder =
    match config.raw_trace with
    | Some raw_trace -> Oas.Builder.with_raw_trace raw_trace builder
    | None -> builder
  in
  let builder =
    match config.tool_retry_policy with
    | Some policy -> Oas.Builder.with_tool_retry_policy policy builder
    | None -> builder
  in
  let builder =
    Oas.Builder.with_required_tool_satisfaction config.required_tool_satisfaction builder
  in
  let builder =
    match config.enable_thinking with
    | Some enabled -> Oas.Builder.with_enable_thinking enabled builder
    | None -> builder
  in
  let builder =
    match config.priority with
    | Some priority -> Oas.Builder.with_priority priority builder
    | None -> builder
  in
  let builder =
    match config.max_cost_usd with
    | Some usd -> Oas.Builder.with_max_cost_usd usd builder
    | None -> builder
  in
  let builder =
    match config.max_input_tokens with
    | Some tokens -> Oas.Builder.with_max_input_tokens tokens builder
    | None -> builder
  in
  let builder =
    match config.runtime_mcp_policy with
    | Some policy -> Oas.Builder.with_runtime_mcp_policy policy builder
    | None -> builder
  in
  let builder =
    if config.cache_system_prompt
    then Oas.Builder.with_cache_system_prompt true builder
    else builder
  in
  let builder =
    if config.yield_on_tool then Oas.Builder.with_yield_on_tool true builder else builder
  in
  let builder =
    if config.allowed_paths <> []
    then Oas.Builder.with_allowed_paths config.allowed_paths builder
    else builder
  in
  let builder =
    if config.initial_messages <> []
    then Oas.Builder.with_initial_messages config.initial_messages builder
    else builder
  in
  let builder =
    match config.compact_ratio with
    | Some ratio -> Oas.Builder.with_context_thresholds ~compact_ratio:ratio builder
    | None -> builder
  in
  let builder =
    match config.context_injector with
    | Some injector -> Oas.Builder.with_context_injector injector builder
    | None -> builder
  in
  let builder =
    match config.context with
    | Some ctx -> Oas.Builder.with_context ctx builder
    | None -> builder
  in
  let builder =
    match config.slot_id with
    | Some id -> Oas.Builder.with_slot_id id builder
    | None -> builder
  in
  let builder =
    match config.exit_condition with
    | Some cond -> Oas.Builder.with_exit_condition cond builder
    | None -> builder
  in
  let builder =
    match config.summarizer with
    | Some s -> Oas.Builder.with_summarizer s builder
    | None -> builder
  in
  match transport with
  | Some transport -> Oas.Builder.with_transport transport builder
  | None -> builder
;;

type prepared_resume =
  { patched_checkpoint : Oas.Checkpoint.t
  ; agent_config : Oas.Types.agent_config
  ; options : Oas.Agent.options
  }

let prepare_resume ~(config : config) ~(checkpoint : Oas.Checkpoint.t) : prepared_resume =
  let effective_max_turns = checkpoint.turn_count + config.max_turns in
  let effective_max_cost_usd =
    match config.max_cost_usd with
    | Some budget -> Some (checkpoint.usage.estimated_cost_usd +. budget)
    | None -> None
  in
  let patched_checkpoint =
    { checkpoint with
      Oas.Checkpoint.model = config.model_id
    ; system_prompt = Some config.system_prompt
    ; temperature = Some config.temperature
    ; enable_thinking = config.enable_thinking
    ; cache_system_prompt = config.cache_system_prompt
    ; max_input_tokens = config.max_input_tokens
    ; max_total_tokens = None
    }
  in
  let agent_config : Oas.Types.agent_config =
    { Oas.Types.default_config with
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
  let options : Oas.Agent.options =
    { Oas.Agent.default_options with
      provider = Some config.provider
    ; hooks = Option.value ~default:Oas.Hooks.empty config.hooks
    ; max_idle_turns = config.max_idle_turns
    ; stream_idle_timeout_s = config.stream_idle_timeout_s
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

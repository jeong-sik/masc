(** Oas_worker_named — Named cascade and model-label execution entry points.

    Public API for running OAS agents with cascade fallback ([run_named])
    or explicit model label ([run_model_by_label]), with optional MASC
    tool bridging variants.

    @since God file decomposition — extracted from oas_worker.ml *)

(* ================================================================ *)
(* Cascade profile defaults (moved from Cascade module)              *)
(* ================================================================ *)

let default_config_path () : string option =
  Config_dir_resolver.log_warnings ~context:"OasWorker" ();
  Config_dir_resolver.cascade_path_opt ()

(** Hardcoded fallback defaults — used only when cascade.json is missing
    and the cascade name has no "{name}_models" entry.
    All profiles are now in config/cascade.json (hot-reloadable). *)
let default_model_strings ~cascade_name:_ =
  match Provider_adapter.explicit_llama_model_label_result () with
  | Ok label -> [ label ]
  | Error _ -> (
      match Provider_adapter.preferred_execution_model_labels () with
      | [] -> [ Provider_adapter.default_local_fallback_label () ]
      | labels -> labels)

(* ================================================================ *)
(* Named model execution                                            *)
(* ================================================================ *)

let require_eio ?sw ?net () =
  let sw = match sw with Some s -> Some s | None -> Eio_context.get_switch_opt () in
  let net = match net with Some n -> Some n | None -> Eio_context.get_net_opt () in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

(** Resolve cascade provider configs via OAS Cascade_config.
    Returns OAS Provider_config.t list directly, bypassing the old Model_spec facade. *)
let resolve_cascade_providers ~cascade_name : Llm_provider.Provider_config.t list =
  let defaults = default_model_strings ~cascade_name in
  let config_path = default_config_path () in
  let configured =
    Llm_provider.Cascade_config.resolve_model_strings
      ?config_path ~name:cascade_name ~defaults ()
  in
  let specs = Llm_provider.Cascade_config.parse_model_strings configured in
  if specs <> [] then specs
  else if configured = defaults then (
      Log.Misc.warn "cascade %s: no callable models from built-in defaults" cascade_name;
      [])
    else (
      Log.Misc.warn "cascade %s: configured models unavailable — retrying built-in defaults" cascade_name;
      Llm_provider.Cascade_config.parse_model_strings defaults)

let config_for_label
    ~(name : string)
    ~(model_label : string)
    ~(system_prompt : string)
    ~(tools : Agent_sdk.Tool.t list)
    ~(max_turns : int)
    ~(max_tokens : int)
    ?(max_input_tokens : int option)
    ?(max_cost_usd : float option)
    ~(temperature : float)
    ?(max_idle_turns = 3)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?contract
    ?approval
    ~(description : string option)
    () : Oas_worker_exec.config =
  let provider = Oas_worker_exec.resolve_provider_of_label model_label in
  let model_id = match Oas_model_resolve.provider_name_of_label model_label with
    | Some _ ->
      (match String.index_opt model_label ':' with
       | Some idx -> String.sub model_label (idx + 1) (String.length model_label - idx - 1) |> String.trim
       | None -> model_label)
    | None -> model_label
  in
  {
    (Oas_worker_exec.default_config ~name ~provider ~model_id
       ~system_prompt ~tools)
    with
    max_turns;
    max_tokens;
    max_input_tokens;
    max_cost_usd;
    temperature;
    max_idle_turns;
    guardrails;
    hooks;
    context_reducer;
    memory;
    tool_retry_policy;
    enable_thinking;
    contract;
    description;
    compact_ratio;
    approval;
  }

(** Run a single Agent.run() call with cascade model fallback.

    Tries each model in cascade order. Falls through to the next model
    when:
    - Agent.run() returns an error (model unavailable, network issue)
    - [accept] returns [false] (response validation failure)

    @param accept Optional response validator. Default accepts all.
    @since Phase 7 — cascade fallback in Oas_worker *)
let run_named
    ~cascade_name
    ~goal
    ?provider_filter
    ?priority
    ?session_id
    ?(system_prompt = "")
    ?(tools = [])
    ?(initial_messages = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?(accept = fun (_ : Oas_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?proof_ref
    ?contract
    ?transport
    ?(allowed_paths = [])
    ?checkpoint_sidecar
    ?(cache_system_prompt = false)
    ?(yield_on_tool = false)
    ?compact_ratio
    ?checkpoint_dir
    ?context_injector
    ?context
    ?slot_id
    ?enable_thinking
    ?approval
    ?exit_condition
    ?oas_checkpoint
    ?event_bus
    ?sw
    ?net
    ()
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (Oas.Error.Internal e)
  | Ok (sw, net) ->
  let defaults = default_model_strings ~cascade_name in
  let config_path = default_config_path () in
  let configured_labels =
    Llm_provider.Cascade_config.resolve_model_strings
      ?config_path ~name:cascade_name ~defaults ()
  in
  let candidate_cfgs = resolve_cascade_providers ~cascade_name in
  let capture, metrics = Oas_worker_cascade.cascade_metrics_for_candidates ~candidate_cfgs () in
  let named_cascade = Agent_sdk.Api.named_cascade ?config_path
    ~metrics ?provider_filter ~name:cascade_name ~defaults () in
  let name = Printf.sprintf "oas-%s" cascade_name in
  match candidate_cfgs with
  | [] ->
    Log.Misc.error "cascade %s: no callable models available" cascade_name;
    Error (Oas.Error.Internal
      (Printf.sprintf "cascade %s: no callable models available" cascade_name))
  | primary_provider :: _ ->
  let provider : Agent_sdk.Provider.config =
    Agent_sdk.Provider.config_of_provider_config primary_provider
  in
  let transport_resolved = match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  let config : Oas_worker_exec.config =
    { (Oas_worker_exec.default_config ~name ~provider ~model_id:primary_provider.model_id
      ~system_prompt ~tools)
    with
      priority;
      max_turns; max_tokens; max_input_tokens; max_cost_usd; temperature; max_idle_turns;
      guardrails; hooks; context_reducer; memory; tool_retry_policy;
      description = Some (Printf.sprintf "cascade:%s" cascade_name);
      transport = transport_resolved;
      allowed_paths;
      checkpoint_sidecar;
      session_id;
      cache_system_prompt;
      compact_ratio;
      contract;
      checkpoint_dir;
      context_injector;
      context;
      slot_id;
      enable_thinking;
      event_bus;
      approval;
      exit_condition;
    }
  in
  let config = { config with named_cascade = Some named_cascade; initial_messages; raw_trace; yield_on_tool } in
  let queue_priority =
    Option.value priority ~default:Llm_provider.Request_priority.Proactive
  in
  Admission_queue.with_permit
    ~priority:queue_priority ~keeper_name:name ~cascade_name
    (fun () ->
  match Oas_worker_exec.run ~sw ~net ~config ?oas_checkpoint ?on_event ?on_yield ?on_resume ?agent_ref ?proof_ref ?contract goal with
  | Ok result when accept result.response ->
    let observation =
      Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
        ~candidate_cfgs ~selected_model_raw:(Some result.response.model)
        ~capture
    in
    let result = { result with cascade_observation = Some observation } in
    Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
    Ok result
  | Ok result ->
    let observation =
      Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
        ~candidate_cfgs ~selected_model_raw:(Some result.response.model)
        ~capture
    in
    Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Rejected ~observation:(Some observation);
    Error (Oas.Error.Internal
      (Printf.sprintf "cascade %s: response rejected by accept" cascade_name))
  | Error e ->
    let observation =
      Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
        ~candidate_cfgs ~selected_model_raw:None ~capture
    in
    Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
    Error e)

(** Run a single Agent.run() using a model label string (e.g. "llama:qwen3.5").
    Validates the label parses before attempting execution. *)
let run_model_by_label
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?(accept = fun (_ : Oas_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?contract
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  (match Llm_provider.Cascade_config.parse_model_string model_label with
  | None ->
    Error (Oas.Error.Internal
      (Printf.sprintf "Cannot parse model label: %s" model_label))
  | Some _pc ->
    match require_eio ?sw ?net () with
    | Error e -> Error (Oas.Error.Internal e)
    | Ok (sw, net) ->
        let transport_resolved = match transport with
          | Some t -> t
          | None -> Masc_grpc_transport.from_env ()
        in
        let config =
          config_for_label ~name:"oas-label-model" ~model_label ~system_prompt
            ~tools ~max_turns ~max_tokens ?max_input_tokens ?max_cost_usd ~temperature
            ~max_idle_turns ?guardrails ?hooks ?context_reducer ?memory
            ?tool_retry_policy
            ?enable_thinking
            ?compact_ratio
            ~description:(Some (Printf.sprintf "model_label:%s" model_label))
            ()
        in
        let config = { config with transport = transport_resolved } in
        Admission_queue.with_permit
          ~priority:Llm_provider.Request_priority.Proactive
          ~keeper_name:"oas-label-model"
          ~cascade_name:model_label
          (fun () ->
        match Oas_worker_exec.run ~sw ~net ~config ?on_event ?contract goal with
        | Ok result when accept result.response -> Ok result
        | Ok _ ->
            Error (Oas.Error.Internal
              (Printf.sprintf "response rejected by accept from %s" model_label))
        | Error e -> Error e))

let run_named_with_masc_tools
    ~cascade_name
    ~goal
    ?priority
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?guardrails
    ?hooks
    ?memory
    ?tool_retry_policy
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?proof_ref
    ?contract
    ?transport
    ?(yield_on_tool = false)
    ?compact_ratio
    ?sw
    ?net
    ()
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  let oas_tools = List.map (fun (td : Types.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  run_named ~cascade_name ~goal ?priority ~system_prompt ~tools:oas_tools
    ~max_turns ~temperature ~max_tokens ?max_input_tokens ?max_cost_usd ?guardrails ?hooks ?memory
    ?tool_retry_policy
    ?compact_ratio
    ?raw_trace ?on_event ?on_yield ?on_resume ?proof_ref
    ?contract
    ?transport ~yield_on_tool ?sw ?net ()

let run_model_with_masc_tools
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?guardrails
    ?hooks
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?contract
    ?raw_trace
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (Oas.Error.Internal e)
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
        let config =
          config_for_label ~name:"oas-explicit-model" ~model_label ~system_prompt
          ~tools:[] ~max_turns ~max_tokens ?max_input_tokens ?max_cost_usd ~temperature ?guardrails ?hooks
          ?memory ?tool_retry_policy ?enable_thinking
          ?compact_ratio
          ~description:(Some (Printf.sprintf "model_label:%s" model_label))
          ()
      in
      let config = { config with raw_trace; transport = transport_resolved } in
      Admission_queue.with_permit
        ~priority:Llm_provider.Request_priority.Proactive
        ~keeper_name:"oas-explicit-model"
        ~cascade_name:model_label
        (fun () ->
      Oas_worker_exec.run_with_masc_tools ~sw ~net ~config ~masc_tools ~dispatch ?contract ?on_event
        goal)

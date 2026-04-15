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

(** True when cascade_name implies local-only routing (e.g. "local_only").
    Convention: any name containing "local" restricts defaults to
    self-hosted providers so that cloud models never leak in via fallback. *)
let is_local_only_cascade name =
  let lc = name |> Keeper_cascade_profile.canonicalize |> String.lowercase_ascii in
  let pattern = "local" in
  let plen = String.length pattern in
  let slen = String.length lc in
  let rec loop i =
    if i > slen - plen then false
    else if String.sub lc i plen = pattern then true
    else loop (i + 1)
  in
  loop 0

let is_local_label label =
  match Oas_model_resolve.provider_name_of_label label with
  | Some pname -> Provider_adapter.is_local_provider pname
  | None -> false

(** Hardcoded fallback defaults — used only when cascade.json is missing
    and the cascade name has no "{name}_models" entry.
    When cascade_name contains "local", only self-hosted providers are
    returned to prevent cloud models from leaking into local-only cascades.
    All profiles are now in config/cascade.json (hot-reloadable). *)
let default_model_strings ~cascade_name =
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  let all_labels =
    match Provider_adapter.explicit_llama_model_label_result () with
    | Ok label -> [ label ]
    | Error _ -> (
        match Provider_adapter.preferred_execution_model_labels () with
        | [] -> [ Provider_adapter.default_local_fallback_label () ]
        | labels -> labels)
  in
  if is_local_only_cascade cascade_name then
    match List.filter is_local_label all_labels with
    | [] -> [ Provider_adapter.default_local_fallback_label () ]
    | local -> local
  else
    all_labels

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

let admission_wait_timeout_error
    ~(keeper_name : string)
    ~(cascade_name : string)
    ~(priority : Llm_provider.Request_priority.t)
    (wait_ms : int) =
  let wait_sec = float_of_int wait_ms /. 1000.0 in
  let msg =
    Printf.sprintf
      "Admission queue wait timeout after %.1fs (wait_ms=%d, keeper=%s, cascade=%s, priority=%s)"
      wait_sec wait_ms keeper_name cascade_name
      (Llm_provider.Request_priority.to_string priority)
  in
  Log.Misc.warn "%s" msg;
  Error (Oas.Error.Internal msg)

(** Resolve cascade provider configs via OAS Cascade_config.
    Returns OAS Provider_config.t list directly, bypassing the old Model_spec facade. *)
let resolve_cascade_providers ~cascade_name : Llm_provider.Provider_config.t list =
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  let defaults = default_model_strings ~cascade_name in
  let config_path = default_config_path () in
  let configured =
    Cascade_config.resolve_model_strings
      ?config_path ~name:cascade_name ~defaults ()
  in
  let specs = Cascade_config.parse_model_strings configured in
  if specs <> [] then specs
  else if configured = defaults then (
      Log.Misc.warn "cascade %s: no callable models from built-in defaults" cascade_name;
      [])
    else (
      Log.Misc.warn "cascade %s: configured models unavailable — retrying built-in defaults" cascade_name;
      Cascade_config.parse_model_strings defaults)

(** Resolve from an explicit model string list (user-declared in keeper TOML).
    MASC passes strings through without interpretation — OAS parses them. *)
let resolve_providers_from_model_strings (model_strings : string list)
    : Llm_provider.Provider_config.t list =
  let specs = Cascade_config.parse_model_strings model_strings in
  if specs <> [] then specs
  else (
    Log.Misc.warn "direct model strings: no callable models from %d entries"
      (List.length model_strings);
    [])

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

(** Convert an OAS sdk_error into a Cascade_fsm provider_outcome.
    API-level errors and model-capability-dependent agent errors are
    cascadeable (a different provider may succeed).  Structural agent
    errors (budget, idle, exit) are not — they would recur on any model. *)
let sdk_error_to_cascade_outcome (err : Oas.Error.sdk_error)
    : Cascade_fsm.provider_outcome option =
  match err with
  | Oas.Error.Api api_err ->
    let http_err = match api_err with
      | Llm_provider.Retry.InvalidRequest { message } ->
        Llm_provider.Http_client.HttpError { code = 400; body = message }
      | Llm_provider.Retry.ContextOverflow { message; _ } ->
        Llm_provider.Http_client.HttpError { code = 400; body = message }
      | Llm_provider.Retry.RateLimited { message; _ } ->
        Llm_provider.Http_client.HttpError { code = 429; body = message }
      | Llm_provider.Retry.ServerError { status; message } ->
        Llm_provider.Http_client.HttpError { code = status; body = message }
      | Llm_provider.Retry.AuthError { message } ->
        Llm_provider.Http_client.HttpError { code = 401; body = message }
      | Llm_provider.Retry.Overloaded { message } ->
        Llm_provider.Http_client.HttpError { code = 529; body = message }
      | Llm_provider.Retry.NetworkError { message }
      | Llm_provider.Retry.Timeout { message } ->
        Llm_provider.Http_client.NetworkError { message }
    in
    Some (Cascade_fsm.Call_err http_err)
  (* Model-capability errors: the next provider may handle these.
     CompletionContractViolation: model returned text when tool_use was
     required — a different model with better tool calling may succeed.
     UnrecognizedStopReason: model returned a non-standard stop reason
     that this provider does not map — another provider may not. *)
  | Oas.Error.Agent (Oas.Error.CompletionContractViolation { reason; _ }) ->
    Some (Cascade_fsm.Call_err
      (Llm_provider.Http_client.AcceptRejected { reason }))
  | Oas.Error.Agent (Oas.Error.UnrecognizedStopReason { reason }) ->
    Some (Cascade_fsm.Call_err
      (Llm_provider.Http_client.AcceptRejected { reason }))
  | _ -> None

(** Run a single Agent.run() call with MASC-driven cascade model fallback.

    MASC drives the cascade FSM directly:
    - Resolves cascade providers from cascade.json
    - For each provider, runs OAS with a single provider
    - Uses Cascade_fsm.decide to determine next action on failure
    - Cascade loop runs inside Admission_queue permit

    @param accept Optional response validator. Default accepts all.
    @since Phase 2 — MASC-driven cascade FSM *)
let run_named
    ~cascade_name
    ?model_strings
    ~goal
    ?provider_filter:_provider_filter
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
    ?wait_timeout_sec
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
    ?exit_condition_result
    ?oas_checkpoint
    ?event_bus
    ?sw
    ?net
    ()
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (Oas.Error.Internal e)
  | Ok (sw, net) ->
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  let config_path = default_config_path () in
  let configured_labels, candidate_cfgs =
    match model_strings with
    | Some ms when ms <> [] ->
      (* Direct model strings from keeper TOML — skip named preset lookup.
         MASC passes these strings through without interpretation. *)
      (ms, resolve_providers_from_model_strings ms)
    | _ ->
      (* Legacy path: resolve from cascade.json by name *)
      let defaults = default_model_strings ~cascade_name in
      let labels =
        Cascade_config.resolve_model_strings
          ?config_path ~name:cascade_name ~defaults ()
      in
      (labels, resolve_cascade_providers ~cascade_name)
  in
  let capture, metrics = Oas_worker_cascade.cascade_metrics_for_candidates ~candidate_cfgs () in
  let name = Printf.sprintf "oas-%s" cascade_name in
  match candidate_cfgs with
  | [] ->
    Log.Misc.error "cascade %s: no callable models available" cascade_name;
    Error (Oas.Error.Internal
      (Printf.sprintf "cascade %s: no callable models available" cascade_name))
  | _ ->
  let transport_resolved = match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  let queue_priority =
    Option.value priority ~default:Llm_provider.Request_priority.Proactive
  in
  (* MASC-driven cascade FSM: try each provider, decide on failure.
     Mid-turn resume: when a provider fails after completing some turns,
     the next provider resumes from the failed agent's checkpoint instead
     of restarting from scratch.

     Immutable checkpoint threading: try_provider returns both the result
     and the agent's checkpoint (if progress was made). try_cascade
     threads this checkpoint to the next provider without mutable state. *)
  let try_provider ?resume_checkpoint (provider_cfg : Llm_provider.Provider_config.t) =
    let provider : Agent_sdk.Provider.config =
      Agent_sdk.Provider.config_of_provider_config provider_cfg
    in
    let config : Oas_worker_exec.config =
      { (Oas_worker_exec.default_config ~name ~provider ~model_id:provider_cfg.model_id
        ~system_prompt ~tools)
      with
        priority;
        max_turns; max_tokens; max_input_tokens; max_cost_usd; temperature; max_idle_turns;
        guardrails; hooks; context_reducer; memory; tool_retry_policy;
        description = Some (Printf.sprintf "cascade:%s/%s" cascade_name provider_cfg.model_id);
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
        exit_condition_result;
        initial_messages; raw_trace; yield_on_tool;
      }
    in
    let effective_checkpoint = match resume_checkpoint with
      | Some _ -> resume_checkpoint
      | None -> oas_checkpoint
    in
    let local_agent_ref : Oas.Agent.t option ref = ref None in
    let result =
      Oas_worker_exec.run ~sw ~net ~config ?oas_checkpoint:effective_checkpoint ?on_event
        ?on_yield ?on_resume ~agent_ref:local_agent_ref ?proof_ref ?contract goal
    in
    (* Extract checkpoint from the agent if it made progress.
       The agent's mutable state reflects all completed turns even on Error. *)
    let checkpoint_after = match !local_agent_ref with
      | Some agent when (Oas.Agent.state agent).turn_count > 0 ->
        (* Also propagate to caller's agent_ref for final result *)
        (match agent_ref with Some r -> r := Some agent | None -> ());
        Some (Oas.Agent.checkpoint agent)
      | Some agent ->
        (match agent_ref with Some r -> r := Some agent | None -> ());
        None
      | None -> None
    in
    (result, checkpoint_after)
  in
  let rec try_cascade ?resume_checkpoint remaining last_err =
    match remaining with
    | [] ->
      let err_msg = match last_err with
        | Some (Llm_provider.Http_client.HttpError { code; body }) ->
          Printf.sprintf "HTTP %d: %s" code
            (if String.length body > 200 then String.sub body 0 200 ^ "..." else body)
        | Some (Llm_provider.Http_client.AcceptRejected { reason }) -> reason
        | Some (Llm_provider.Http_client.NetworkError { message }) -> message
        | None -> "no providers available"
      in
      let observation =
        Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
          ~candidate_cfgs ~selected_model_raw:None ~capture
      in
      Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
      Error (Oas.Error.Internal
        (Printf.sprintf "cascade %s: all models failed: %s" cascade_name err_msg))
    | (provider_cfg : Llm_provider.Provider_config.t) :: rest ->
      let is_last = rest = [] in
      Log.Misc.debug "cascade %s: trying %s (is_last=%b)" cascade_name provider_cfg.model_id is_last;
      let (result, checkpoint_after) = try_provider ?resume_checkpoint provider_cfg in
      (* Thread checkpoint forward: if this provider made progress,
         the next provider can resume from where this one left off. *)
      let next_resume = match checkpoint_after with
        | Some _ -> checkpoint_after
        | None -> resume_checkpoint
      in
      (match result with
      | Ok result when accept result.response ->
        (* FSM: Call_ok → Accept *)
        let observation =
          Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
            ~candidate_cfgs ~selected_model_raw:(Some result.response.model) ~capture
        in
        let result = { result with cascade_observation = Some observation } in
        Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
        Ok result
      | Ok result ->
        (* FSM: Accept_rejected → decide *)
        let reason = Printf.sprintf "response rejected by accept (model=%s)" result.response.model in
        let outcome = Cascade_fsm.Accept_rejected
          { response = result.response; reason } in
        (match Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome with
         | Cascade_fsm.Accept_on_exhaustion { response; _ } ->
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some response.model) ~capture
           in
           let result = { result with cascade_observation = Some observation } in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
           Ok result
         | Cascade_fsm.Try_next { last_err = new_err } ->
           Log.Misc.warn "cascade %s: accept rejected %s (%s), trying next" cascade_name provider_cfg.model_id reason;
           metrics.on_cascade_fallback ~from_model:provider_cfg.model_id ~to_model:"next" ~reason;
           try_cascade ?resume_checkpoint:next_resume rest new_err
         | Cascade_fsm.Exhausted _ ->
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some result.response.model) ~capture
           in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Rejected ~observation:(Some observation);
           Error (Oas.Error.Internal
             (Printf.sprintf "cascade %s: %s" cascade_name reason))
         | Cascade_fsm.Accept resp ->
           (* Should be unreachable with accept_on_exhaustion:false, but handle gracefully *)
           Log.Misc.warn "cascade %s: unexpected Accept in Accept_rejected branch (model=%s)" cascade_name resp.model;
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some resp.model) ~capture
           in
           let result = { result with cascade_observation = Some observation } in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
           Ok result)
      | Error sdk_err ->
        (* FSM: Call_err → decide *)
        (match sdk_error_to_cascade_outcome sdk_err with
         | Some outcome ->
           (match Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome with
            | Cascade_fsm.Try_next { last_err = new_err } ->
              Log.Misc.warn "cascade %s: %s failed (%s), trying next" cascade_name provider_cfg.model_id (Oas.Error.to_string sdk_err);
              metrics.on_cascade_fallback ~from_model:provider_cfg.model_id ~to_model:"next"
                ~reason:(Oas.Error.to_string sdk_err);
              try_cascade ?resume_checkpoint:next_resume rest new_err
            | Cascade_fsm.Exhausted _ ->
              let observation =
                Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
                  ~candidate_cfgs ~selected_model_raw:None ~capture
              in
              Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
              Error sdk_err
            | _ -> Error sdk_err)
         | None ->
           (* Non-API error (agent, config, etc.) — not cascadeable *)
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
               ~candidate_cfgs ~selected_model_raw:None ~capture
           in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
           Error sdk_err))
  in
  try
    Admission_queue.with_permit ?wait_timeout_sec
      ~priority:queue_priority ~keeper_name:name ~cascade_name
      (fun () -> try_cascade candidate_cfgs None)
  with
  | Admission_queue.Wait_timeout wait_ms ->
      admission_wait_timeout_error ~keeper_name:name ~cascade_name
        ~priority:queue_priority wait_ms

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
    ?wait_timeout_sec
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
  (match Cascade_config.parse_model_string model_label with
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
        try
          Admission_queue.with_permit ?wait_timeout_sec
            ~priority:Llm_provider.Request_priority.Proactive
            ~keeper_name:"oas-label-model"
            ~cascade_name:model_label
            (fun () ->
              match Oas_worker_exec.run ~sw ~net ~config ?on_event ?contract goal with
              | Ok result when accept result.response -> Ok result
              | Ok _ ->
                  Error (Oas.Error.Internal
                    (Printf.sprintf "response rejected by accept from %s" model_label))
              | Error e -> Error e)
        with
        | Admission_queue.Wait_timeout wait_ms ->
            admission_wait_timeout_error ~keeper_name:"oas-label-model"
              ~cascade_name:model_label
              ~priority:Llm_provider.Request_priority.Proactive wait_ms)

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
    ?wait_timeout_sec
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
    ~max_turns ~temperature ~max_tokens ?max_input_tokens ?max_cost_usd
    ?wait_timeout_sec ?guardrails ?hooks ?memory
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
    ?wait_timeout_sec
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
      try
        Admission_queue.with_permit ?wait_timeout_sec
          ~priority:Llm_provider.Request_priority.Proactive
          ~keeper_name:"oas-explicit-model"
          ~cascade_name:model_label
          (fun () ->
            Oas_worker_exec.run_with_masc_tools ~sw ~net ~config ~masc_tools ~dispatch ?contract ?on_event
              goal)
      with
      | Admission_queue.Wait_timeout wait_ms ->
          admission_wait_timeout_error ~keeper_name:"oas-explicit-model"
            ~cascade_name:model_label
            ~priority:Llm_provider.Request_priority.Proactive wait_ms

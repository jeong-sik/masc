(** Keeper_turn_driver_helpers — pure helper functions extracted from
    [Keeper_turn_driver].

    These are top-level pure functions (no closures over outer state)
    that compute provider-attempt timeout bounds, health-key derivations,
    tool-name aggregations, etc. Lifting them out of the 1459-LOC
    [keeper_turn_driver.ml] is a foundation step toward the eventual
    A/B/C decomposition (Agent SDK call / cascade strategy / keeper
    bookkeeping) deferred from RFC-0047 Phase 4.

    No behavior change. Mechanical extraction.

    @since RFC-0048 — keeper_turn_driver split, helpers slice *)

let provider_health_keys_of_config provider_cfg =
  let provider_key = Provider_adapter.provider_health_key_of_config provider_cfg in
  let model_key =
    Provider_adapter.provider_model_health_key_of_config provider_cfg
  in
  if String.equal provider_key model_key then [ provider_key ]
  else [ provider_key; model_key ]

let first_health_cooldown provider_cfg =
  provider_health_keys_of_config provider_cfg
  |> List.find_map (fun provider_key ->
         match
           Cascade_health_tracker.check_circuit_breaker
             Cascade_health_tracker.global
             ~provider_key
         with
         | Ok () -> None
         | Error msg -> Some (provider_key, msg))

type provider_attempt_timeout_constraints = {
  min_timeout_s : float option;
  max_timeout_s : float option;
}

let provider_attempt_timeout_constraints
    (provider_cfg : Llm_provider.Provider_config.t) =
  match provider_cfg.kind with
  | Llm_provider.Provider_config.Ollama ->
      { min_timeout_s = Some 300.0; max_timeout_s = None }
  | Claude_code ->
      { min_timeout_s = None; max_timeout_s = Some 120.0 }
  | Gemini | Gemini_cli ->
      { min_timeout_s = None; max_timeout_s = Some 180.0 }
  | Kimi_cli ->
      { min_timeout_s = None; max_timeout_s = Some 60.0 }
  | Anthropic | Kimi | OpenAI_compat | Glm | DashScope | Codex_cli ->
      { min_timeout_s = None; max_timeout_s = None }

let apply_provider_attempt_timeout_constraints constraints timeout_s =
  let timeout_s =
    match constraints.min_timeout_s with
    | Some min_s -> Float.max timeout_s min_s
    | None -> timeout_s
  in
  match constraints.max_timeout_s with
  | Some max_s -> Float.min timeout_s max_s
  | None -> timeout_s

let provider_default_attempt_timeout_s constraints =
  match constraints.min_timeout_s, constraints.max_timeout_s with
  | Some min_s, Some max_s -> Some (Float.min max_s min_s)
  | Some min_s, None -> Some min_s
  | None, Some max_s -> Some max_s
  | None, None -> None

let effective_provider_attempt_timeout_s
    ~(is_last : bool)
    ~(configured_timeout_s : float option)
    (provider_cfg : Llm_provider.Provider_config.t) : float option =
  let constraints = provider_attempt_timeout_constraints provider_cfg in
  match configured_timeout_s with
  | Some configured ->
      let bounded =
        apply_provider_attempt_timeout_constraints constraints configured
      in
      if is_last
         && Option.is_none constraints.min_timeout_s
         && Option.is_none constraints.max_timeout_s
      then None
      else Some bounded
  | None ->
      provider_default_attempt_timeout_s constraints

let required_tool_names_for_no_tool_error ~runtime_mcp_policy ~tools =
  let names =
    match runtime_mcp_policy with
    | Some policy
      when policy.Llm_provider.Llm_transport.allowed_tool_names <> [] ->
        policy.allowed_tool_names
    | _ -> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) tools
  in
  List.sort_uniq String.compare names

let provider_rejections_for_no_tool_error
    ~keeper_name ?runtime_mcp_policy ~tools
    ~require_tool_choice_support ~require_tool_support provider_cfgs =
  provider_cfgs
  |> List.filter_map (fun provider_cfg ->
       match
         Cascade_oas_runner.classify_filter_rejection
           ~keeper_name ?runtime_mcp_policy ~tools
           ~require_tool_choice_support ~require_tool_support provider_cfg
       with
       | None -> None
       | Some reason ->
           Some
             ({
                provider_label =
                  Provider_tool_support.provider_debug_label provider_cfg;
                provider_kind =
                  Provider_tool_support.provider_kind_label provider_cfg;
                reason = Cascade_oas_runner.filter_rejection_reason_label reason;
              } : Cascade_error_classify.provider_rejection))

let apply_stream_idle_timeout_default = function
  | Some _ as v -> v
  | None -> Some Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec

let checkpoint_after_attempt ?agent_ref = function
  | Some agent ->
      (match agent_ref with Some r -> r := Some agent | None -> ());
      Some (Agent_sdk.Agent.checkpoint agent)
  | None -> None

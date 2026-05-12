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
  let provider_key = Runtime_catalog.provider_health_key_of_config provider_cfg in
  let model_key =
    Runtime_catalog.provider_model_health_key_of_config provider_cfg
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

(* Manifest alias of [Runtime_catalog.timeout_bounds]: keeps the
   keeper-public type name stable while the [match provider_cfg.kind]
   that produces values lives inside the adapter boundary
   (RFC-0058 Phase 5.6). *)
type provider_attempt_timeout_constraints = Runtime_catalog.timeout_bounds = {
  min_timeout_s : float option;
  max_timeout_s : float option;
}

let provider_attempt_timeout_constraints
    (provider_cfg : Llm_provider.Provider_config.t) =
  Runtime_catalog.timeout_bounds_of_kind provider_cfg.kind

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

let dedupe_keep_order values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
      if List.mem value seen then loop seen acc rest
      else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values

let materialized_tool_names_after_lane ~effective_tools ~runtime_mcp_policy =
  let inline_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) effective_tools
  in
  let runtime_names =
    match runtime_mcp_policy with
    | Some policy -> policy.Llm_provider.Llm_transport.allowed_tool_names
    | None -> []
  in
  dedupe_keep_order (inline_names @ runtime_names)

let resolved_tool_lane_label ~effective_tools ~runtime_mcp_policy =
  let inline_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) effective_tools
  in
  let runtime_names =
    match runtime_mcp_policy with
    | Some policy -> policy.Llm_provider.Llm_transport.allowed_tool_names
    | None -> []
  in
  match inline_names <> [], runtime_names <> [], runtime_mcp_policy with
  | true, true, _ -> "mixed"
  | true, false, _ -> "inline"
  | false, true, _ -> "runtime_mcp"
  | false, false, Some _ -> "runtime_mcp_connect_only"
  | false, false, None -> "none"

let missing_required_tool_names_after_lane_by_name ~required_tool_names
    ~materialized_tool_names =
  required_tool_names
  |> dedupe_keep_order
  |> List.filter (fun name -> not (List.mem name materialized_tool_names))

let missing_required_tool_names_after_lane ~required_tool_names ~effective_tools
    ~runtime_mcp_policy =
  let materialized_tool_names =
    materialized_tool_names_after_lane ~effective_tools ~runtime_mcp_policy
  in
  missing_required_tool_names_after_lane_by_name ~required_tool_names
    ~materialized_tool_names

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

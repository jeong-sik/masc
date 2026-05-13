type t =
  { provider_cfg : Llm_provider.Provider_config.t
  ; health_key : string
  ; model_health_key : string
  ; capacity_key : string
  ; http_probe_url : string option
  }

type context_window_hint =
  { context_window : int
  ; is_local_model : bool
  }

let cli_sentinel_of_kind kind =
  if Llm_provider.Provider_config.is_subprocess_cli kind then
    Some ("cli:" ^ Llm_provider.Provider_config.string_of_provider_kind kind)
  else
    None

let capacity_key_of_config (cfg : Llm_provider.Provider_config.t) =
  if cfg.base_url <> "" then cfg.base_url
  else
    match cli_sentinel_of_kind cfg.kind with
    | Some sentinel -> sentinel
    | None -> ""

let http_probe_url_of_config (cfg : Llm_provider.Provider_config.t) =
  if Provider_adapter.is_http_probe_capable_kind cfg.kind && cfg.base_url <> ""
  then Some cfg.base_url
  else None

let of_provider_config provider_cfg =
  { provider_cfg
  ; health_key = "runtime"
  ; model_health_key = "runtime"
  ; capacity_key = capacity_key_of_config provider_cfg
  ; http_probe_url = http_probe_url_of_config provider_cfg
  }

let of_provider_configs provider_cfgs = List.map of_provider_config provider_cfgs

let runtime_url_of_label label =
  match Cascade_config.parse_model_string label with
  | Some cfg when String.trim cfg.base_url <> "" -> Some cfg.base_url
  | _ -> None

let label_matches_runtime_id ~label ~runtime_id =
  match Cascade_config.parse_model_string label with
  | Some cfg -> String.equal (String.trim cfg.model_id) (String.trim runtime_id)
  | None -> false

let has_resolvable_runtime_label labels =
  List.exists
    (fun label -> Option.is_some (Cascade_config.parse_model_string label))
    labels

let runtime_id_of_label label =
  match Cascade_config.parse_model_string label with
  | Some cfg ->
      let runtime_id = String.trim cfg.model_id in
      if String.equal runtime_id "" then None else Some runtime_id
  | None -> None

let runtime_id_of_label_or_raw label =
  match runtime_id_of_label label with
  | Some runtime_id -> runtime_id
  | None -> String.trim label

let strip_latest_suffix runtime_id =
  let suffix = ":latest" in
  let suffix_len = String.length suffix in
  let len = String.length runtime_id in
  if len > suffix_len
     && String.equal (String.sub runtime_id (len - suffix_len) suffix_len) suffix
  then String.sub runtime_id 0 (len - suffix_len)
  else runtime_id

let normalize_runtime_name_for_bucket label =
  runtime_id_of_label_or_raw label |> strip_latest_suffix

let default_local_runtime_label () =
  Provider_adapter.default_local_fallback_label ()

let local_runtime_label runtime_id =
  Provider_adapter.make_local_label runtime_id

let labels_require_runtime_mcp_header_sync labels =
  List.exists Provider_adapter.supports_runtime_mcp_http_headers_for_model_label labels

let unknown_runtime_label = Provider_adapter.cn_unknown_provider

let provider_label_of_runtime_label ?provider_kind label =
  Provider_adapter.provider_of_model_label ?provider_kind label

let is_structurally_unmetered_runtime_provider provider =
  Provider_adapter.is_structurally_unmetered_provider provider

let canonical_provider_of_label label =
  match String.index_opt label ':' with
  | Some idx when idx > 0 ->
      String.sub label 0 idx
      |> String.trim
      |> Provider_adapter.resolve_direct_canonical_name
  | _ -> Provider_adapter.resolve_direct_canonical_name label

let runtime_label_for_active_id ~configured_labels ~active =
  let active = String.trim active in
  if String.equal active "" then ""
  else if String.contains active ':' then active
  else
    let active_norm = String.lowercase_ascii active in
    let matches_runtime_id label =
      String.lowercase_ascii (runtime_id_of_label_or_raw label) = active_norm
    in
    match List.find_opt matches_runtime_id configured_labels with
    | Some label -> label
    | None ->
        (match Provider_adapter.resolve_direct_adapter active with
         | Some adapter ->
             let matches_provider label =
               canonical_provider_of_label label = Some adapter.canonical_name
             in
             (match List.find_opt matches_provider configured_labels with
              | Some label -> label
              | None ->
                  let runtime_id =
                    match adapter.default_model_id with
                    | Some value when String.trim value <> "" -> value
                    | _ -> "auto"
                  in
                  adapter.cascade_prefix ^ ":" ^ runtime_id)
         | None -> active)

let runtime_health_key_of_label label =
  let _ = label in
  None

let runtime_health_keys_of_labels labels =
  let _ = labels in
  []

let resolve_reported_runtime_id ~labels ~reported_runtime_id =
  let _ = labels in
  let _ = reported_runtime_id in
  "runtime"

let context_window_hint_of_labels labels =
  let _ = labels in
  { context_window = 0; is_local_model = false }

let threshold_multipliers_of_runtime_id runtime_id =
  let _ = runtime_id in
  1.0, 1.0

let health_key candidate = candidate.health_key
let model_health_key candidate = candidate.model_health_key

let health_keys candidate =
  if String.equal candidate.health_key candidate.model_health_key then
    [ candidate.health_key ]
  else
    [ candidate.health_key; candidate.model_health_key ]

let first_health_cooldown candidate =
  let _ = candidate in
  None

let has_recovery_evidence candidate =
  let _ = candidate in
  false

let provider_attempt_timeout_constraints candidate =
  Provider_adapter.timeout_bounds_of_kind candidate.provider_cfg.kind

let apply_provider_attempt_timeout_constraints constraints timeout_s =
  let timeout_s =
    match constraints.Provider_adapter.min_timeout_s with
    | Some min_s -> Float.max timeout_s min_s
    | None -> timeout_s
  in
  match constraints.Provider_adapter.max_timeout_s with
  | Some max_s -> Float.min timeout_s max_s
  | None -> timeout_s

let provider_default_attempt_timeout_s constraints =
  match
    ( constraints.Provider_adapter.min_timeout_s
    , constraints.Provider_adapter.max_timeout_s )
  with
  | Some min_s, Some max_s -> Some (Float.min max_s min_s)
  | Some min_s, None -> Some min_s
  | None, Some max_s -> Some max_s
  | None, None -> None

let effective_attempt_timeout_s ~is_last ~configured_timeout_s candidate =
  let constraints = provider_attempt_timeout_constraints candidate in
  match configured_timeout_s with
  | Some configured ->
      let bounded =
        apply_provider_attempt_timeout_constraints constraints configured
      in
      if is_last
         && Option.is_none constraints.Provider_adapter.min_timeout_s
         && Option.is_none constraints.Provider_adapter.max_timeout_s
      then None
      else Some bounded
  | None -> provider_default_attempt_timeout_s constraints

let resolve_tool_lane_for_oas_tools
    ?agent_name
    ?tool_requirement
    ~tools
    candidate
  =
  Cascade_runner.resolve_tool_lane_for_oas_tools ?agent_name ?tool_requirement
    ~provider_cfg:candidate.provider_cfg ~tools ()

let runtime_mcp_policy_for_agent ~agent_name candidate runtime_mcp_policy =
  Cascade_runner.runtime_mcp_policy_for_provider
    ~provider_cfg:candidate.provider_cfg
    ~agent_name
    runtime_mcp_policy

let default_config ~name ~system_prompt ~tools candidate =
  Cascade_runner.default_config ~name ~provider_cfg:candidate.provider_cfg
    ~system_prompt ~tools

let enrich_sdk_error ~cascade_name candidate =
  Cascade_attempt_fsm.enrich_sdk_error ~cascade_name
    ~provider_cfg:candidate.provider_cfg

let tool_filter_rejection_label
    ~keeper_name
    ?runtime_mcp_policy
    ~tools
    ~require_tool_choice_support
    ~require_tool_support
    candidate
  =
  Cascade_oas_runner.classify_filter_rejection
    ~keeper_name
    ?runtime_mcp_policy
    ~tools
    ~require_tool_choice_support
    ~require_tool_support
    candidate.provider_cfg
  |> Option.map Cascade_oas_runner.filter_rejection_reason_label

let resolve_tool_capable_across_cascades
    ~sw
    ~net
    ~keeper_name
    ?runtime_mcp_policy
    ~tools
    ~require_tool_choice_support
    ~require_tool_support
    ~exclude_cascade
    ()
  =
  Cascade_oas_runner.resolve_tool_capable_provider_across_cascades
    ~sw
    ~net
    ~keeper_name
    ?runtime_mcp_policy
    ~tools
    ~require_tool_choice_support
    ~require_tool_support
    ~exclude_cascade
    ()
  |> Option.map (fun (source_cascade, provider_cfg) ->
         source_cascade, of_provider_config provider_cfg)

let capacity_key candidate = candidate.capacity_key
let capacity_keys candidates = List.map capacity_key candidates

let runtime_urls candidates =
  candidates
  |> List.filter_map (fun candidate ->
         let base_url = candidate.provider_cfg.base_url in
         if base_url = "" then None else Some base_url)

let http_probe_urls candidates =
  candidates |> List.filter_map (fun candidate -> candidate.http_probe_url)

let register_http_probe_capable ~max_concurrent candidate =
  match candidate.http_probe_url with
  | None -> ()
  | Some url ->
      if not (Cascade_client_capacity.is_registered url) then
        Cascade_client_capacity.register ~url ~max_concurrent;
      Cascade_http_probe.register_url ~url

let strategy_adapter : t Cascade_strategy.adapter =
  { health_key; capacity_key; weight = (fun _ -> 1) }

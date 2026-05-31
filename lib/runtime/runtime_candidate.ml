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

type attempt_timeout_resolution =
  { timeout_s : float option
  ; source : string
  }

module Runtime_binding = Agent_sdk.Provider_runtime_binding

let unknown_runtime_label = "unknown_provider"

let runtime_binding_of_label = Runtime_provider_binding.runtime_binding_of_label

let provider_label_of_config cfg =
  match Runtime_binding.binding_for_provider_config cfg with
  | Some binding -> binding.Runtime_binding.id
  | None -> Llm_provider.Provider_registry.provider_name_of_config cfg

let provider_health_key_of_config cfg =
  match cfg.Llm_provider.Provider_config.kind with
  | Llm_provider.Provider_config.OpenAI_compat ->
    let base_url = String.trim cfg.base_url in
    if String.equal base_url "" then provider_label_of_config cfg
    else Printf.sprintf "%s:%s@%s" (provider_label_of_config cfg) cfg.model_id base_url
  | _ -> provider_label_of_config cfg

let provider_model_health_key_of_config cfg =
  Printf.sprintf "%s:%s" (provider_health_key_of_config cfg) cfg.model_id

let provider_name_of_kind kind =
  let cfg = Llm_provider.Provider_config.make ~kind ~model_id:"auto" ~base_url:"" () in
  Llm_provider.Provider_registry.provider_name_of_config cfg

let provider_label_of_provider_kind kind =
  let provider_name = provider_name_of_kind kind in
  match runtime_binding_of_label provider_name with
  | Some binding -> binding.Runtime_binding.id
  | None -> provider_name

let provider_prefix_of_label label =
  let normalized = String.trim label in
  match String.index_opt normalized ':' with
  | Some idx when idx > 0 ->
    Some (String.sub normalized 0 idx |> String.trim |> String.lowercase_ascii)
  | _ -> None

let provider_label_of_explicit_prefix prefix =
  match runtime_binding_of_label prefix with
  | Some binding -> Some binding.Runtime_binding.id
  | None ->
    if String.equal (String.lowercase_ascii (String.trim prefix)) "custom"
    then Some "custom"
    else None

let provider_label_of_runtime_label ?provider_kind model =
  match provider_prefix_of_label model with
  | Some prefix ->
    (match provider_label_of_explicit_prefix prefix with
     | Some provider -> provider
     | None ->
       (match provider_kind with
        | Some kind -> provider_label_of_provider_kind kind
        | None -> unknown_runtime_label))
  | None ->
    (match provider_kind with
     | Some kind -> provider_label_of_provider_kind kind
     | None -> unknown_runtime_label)

let registry_default_base_url provider_name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry provider_name with
  | Some entry -> entry.defaults.base_url
  | None -> ""

let provider_config_of_runtime_label label =
  let cfg_of_kind ~kind ~model_id ~base_url =
    Llm_provider.Provider_config.make ~kind ~model_id ~base_url ()
  in
  match Provider_kind_resolver.resolve label with
  | Registered { provider_name; model_id; kind } ->
    Some (cfg_of_kind ~kind ~model_id ~base_url:(registry_default_base_url provider_name))
  | Custom_url { model_id; base_url } ->
    Some
      (cfg_of_kind
         ~kind:Llm_provider.Provider_config.OpenAI_compat
         ~model_id
         ~base_url)
  | Unknown _ -> None

let cli_sentinel_of_kind _kind = None

let capacity_key_of_config cfg =
  let base_url = String.trim cfg.Llm_provider.Provider_config.base_url in
  if base_url <> ""
  then
    let model_id = String.trim cfg.model_id in
    if model_id <> "" then Printf.sprintf "%s:%s" base_url model_id else base_url
  else
    match cli_sentinel_of_kind cfg.kind with
    | Some sentinel -> sentinel
    | None -> ""

let http_probe_url_of_config cfg =
  if Llm_provider.Provider_config.is_local cfg
  then
    cfg.Llm_provider.Provider_config.base_url
    |> String_util.trim_nonempty
    |> Option.map Masc_network_defaults.normalize_loopback_base_url
  else None

let of_provider_config provider_cfg =
  { provider_cfg
  ; health_key = provider_health_key_of_config provider_cfg
  ; model_health_key = provider_model_health_key_of_config provider_cfg
  ; capacity_key = capacity_key_of_config provider_cfg
  ; http_probe_url = http_probe_url_of_config provider_cfg
  }

let of_provider_configs provider_cfgs = List.map of_provider_config provider_cfgs

let runtime_url_of_label label =
  match Provider_kind_resolver.resolve label with
  | Provider_kind_resolver.Custom_url { base_url; _ } ->
    let base_url = String.trim base_url in
    if String.equal base_url "" then None else Some base_url
  | Provider_kind_resolver.Registered { provider_name; _ } ->
    let base_url = registry_default_base_url provider_name |> String.trim in
    if String.equal base_url "" then None else Some base_url
  | Provider_kind_resolver.Unknown _ -> None

let runtime_id_of_label label =
  match Provider_kind_resolver.resolve label with
  | Provider_kind_resolver.Registered { model_id; _ }
  | Provider_kind_resolver.Custom_url { model_id; _ } ->
    let runtime_id = String.trim model_id in
    if String.equal runtime_id "" then None else Some runtime_id
  | Provider_kind_resolver.Unknown _ -> None

let label_matches_runtime_id ~label ~runtime_id =
  match runtime_id_of_label label with
  | Some label_runtime_id -> String.equal (String.trim label_runtime_id) (String.trim runtime_id)
  | None -> false

let has_resolvable_runtime_label labels =
  List.exists (fun label -> Option.is_some (runtime_id_of_label label)) labels

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

let local_runtime_provider_id () =
  Runtime_binding.all ()
  |> List.find_opt (fun binding ->
    match binding.Runtime_binding.transport with
    | Runtime_binding.Http
    | Runtime_binding.Managed ->
      Runtime_provider_binding.binding_auth_is_no_auth binding
      && Runtime_provider_binding.binding_base_url_is_loopback binding)
  |> Option.map (fun binding -> binding.Runtime_binding.id)

let default_local_runtime_label () =
  match local_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":auto"
  | None -> "auto"

let local_runtime_label runtime_id =
  match local_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":" ^ runtime_id
  | None -> runtime_id

let labels_require_runtime_mcp_header_sync labels =
  labels
  |> List.filter_map provider_config_of_runtime_label
  |> List.exists (fun cfg ->
    (Provider_tool_support.capabilities_of_config cfg).supports_runtime_mcp_http_headers)

let is_structurally_unmetered_runtime_provider provider =
  match runtime_binding_of_label provider with
  | Some binding ->
    not binding.Runtime_binding.capabilities.emits_usage_tokens
  | None -> false

let runtime_label_for_active_id ~configured_labels ~active =
  let active = String.trim active in
  if String.equal active "" then ""
  else if String.contains active ':' then active
  else
    configured_labels
    |> List.find_opt (fun label ->
      String.equal
        (String.lowercase_ascii (runtime_id_of_label_or_raw label))
        (String.lowercase_ascii active))
    |> Option.value ~default:active

let runtime_health_keys_of_labels labels =
  labels
  |> List.filter_map (fun label ->
    provider_config_of_runtime_label label |> Option.map provider_health_key_of_config)
  |> List.sort_uniq String.compare

let resolve_reported_runtime_id ~labels:_ ~reported_runtime_id:_ = "runtime"
let context_window_hint_of_labels _ = { context_window = 0; is_local_model = false }
let threshold_multipliers_of_runtime_id _ = 1.0, 1.0

let health_key candidate = candidate.health_key
let model_health_key candidate = candidate.model_health_key

let health_keys candidate =
  if String.equal candidate.health_key candidate.model_health_key
  then [ candidate.health_key ]
  else [ candidate.health_key; candidate.model_health_key ]

let provider_label candidate =
  provider_label_of_runtime_label
    ~provider_kind:candidate.provider_cfg.kind
    (Printf.sprintf "%s:%s" (provider_label_of_config candidate.provider_cfg) candidate.provider_cfg.model_id)

let default_config ~name ~system_prompt ~tools candidate =
  Runtime_agent.default_config
    ~name
    ~provider_cfg:candidate.provider_cfg
    ~system_prompt
    ~tools

let enrich_sdk_error ~runtime_id candidate err =
  Keeper_runtime_attempt.enrich_sdk_error
    ~runtime_id
    ~provider_cfg:candidate.provider_cfg
    err

let first_health_cooldown _candidate = None
let has_recovery_evidence _candidate = false

let local_runtime_attempt_timeout_floor_s =
  Keeper_attempt_liveness.bootstrap.attempt_wall_max

let effective_attempt_timeout_resolution ~is_last:_ ~configured_timeout_s candidate =
  if Llm_provider.Provider_config.is_local candidate.provider_cfg
  then
    match configured_timeout_s with
    | None -> { timeout_s = Some local_runtime_attempt_timeout_floor_s; source = "local_runtime_floor" }
    | Some timeout_s when timeout_s < local_runtime_attempt_timeout_floor_s ->
      { timeout_s = Some local_runtime_attempt_timeout_floor_s
      ; source = "configured_lifted_to_local_runtime_floor"
      }
    | Some timeout_s -> { timeout_s = Some timeout_s; source = "configured_per_provider_timeout" }
  else
    match configured_timeout_s with
    | None -> { timeout_s = None; source = "unset_oas_default" }
    | Some timeout_s -> { timeout_s = Some timeout_s; source = "configured_per_provider_timeout" }

let effective_attempt_timeout_s ~is_last ~configured_timeout_s candidate =
  (effective_attempt_timeout_resolution ~is_last ~configured_timeout_s candidate).timeout_s

let resolve_tool_lane_for_oas_tools ?agent_name ?tool_requirement ~tools candidate =
  Runtime_agent.resolve_tool_lane_for_oas_tools
    ?agent_name
    ?tool_requirement
    ~provider_cfg:candidate.provider_cfg
    ~tools
    ()

let runtime_mcp_policy_for_agent ~agent_name candidate runtime_mcp_policy =
  Runtime_agent.runtime_mcp_policy_for_provider
    ~provider_cfg:candidate.provider_cfg
    ~agent_name
    runtime_mcp_policy

let tool_filter_rejection_label
      ~keeper_name
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support
      ~require_tool_support
      candidate
  =
  Runtime_oas_runner.classify_filter_rejection
    ~keeper_name
    ?runtime_mcp_policy
    ~tools
    ~require_tool_choice_support
    ~require_tool_support
    candidate.provider_cfg
  |> Option.map Runtime_oas_runner.filter_rejection_reason_label

let capacity_key candidate = candidate.capacity_key
let capacity_keys candidates = List.map capacity_key candidates

let declared_client_capacity candidate =
  match candidate.provider_cfg.internal_model_rotation_count with
  | Some n when n > 0 -> Some n
  | _ -> None

let register_declared_client_capacity _candidate = ()

let runtime_urls candidates =
  candidates
  |> List.filter_map (fun candidate ->
    let base_url = candidate.provider_cfg.base_url in
    if base_url = "" then None else Some base_url)

let local_runtime_url candidate =
  if not (Llm_provider.Provider_config.is_local candidate.provider_cfg)
  then None
  else
    candidate.provider_cfg.base_url
    |> String_util.trim_nonempty
    |> Option.map Masc_network_defaults.normalize_loopback_base_url

let local_runtime_urls candidates =
  candidates |> List.filter_map local_runtime_url |> Json_util.dedupe_keep_order

let endpoint_health_lookup endpoint_health url =
  let normalized_url = Masc_network_defaults.normalize_loopback_base_url url in
  List.find_map
    (fun (endpoint_url, healthy) ->
      let endpoint_url = Masc_network_defaults.normalize_loopback_base_url endpoint_url in
      if String.equal endpoint_url normalized_url then Some healthy else None)
    endpoint_health

let filter_unhealthy_local_runtime_urls ~endpoint_health candidates =
  let kept_rev, dropped =
    List.fold_left
      (fun (kept, dropped) candidate ->
        match local_runtime_url candidate with
        | Some url when endpoint_health_lookup endpoint_health url = Some false ->
          kept, url :: dropped
        | _ -> candidate :: kept, dropped)
      ([], [])
      candidates
  in
  List.rev kept_rev, dropped |> List.rev |> Json_util.dedupe_keep_order

let http_probe_urls candidates =
  candidates |> List.filter_map (fun candidate -> candidate.http_probe_url)

let register_http_probe_capable ~max_concurrent:_ _candidate = ()

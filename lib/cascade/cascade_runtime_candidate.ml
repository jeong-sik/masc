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

module Runtime_binding = Agent_sdk.Provider_runtime_binding

let unknown_runtime_label = "unknown_provider"

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed

let normalize_provider_id provider_id =
  String.trim provider_id
  |> String.lowercase_ascii
  |> String.map (fun c -> if c = '-' then '_' else c)

let runtime_binding_of_label label =
  match Runtime_binding.find label with
  | Some _ as found -> found
  | None -> Runtime_binding.find (normalize_provider_id label)

let binding_endpoint_url (binding : Runtime_binding.t) =
  trim_nonempty binding.Runtime_binding.base_url

let binding_auth_is_no_auth (binding : Runtime_binding.t) =
  match binding.Runtime_binding.auth with
  | Runtime_binding.No_auth -> true
  | Runtime_binding.Api_key_env _
  | Runtime_binding.Cli_cached_login
  | Runtime_binding.Oauth_cached_login
  | Runtime_binding.Setup_token_env _
  | Runtime_binding.File _
  | Runtime_binding.Exec _ -> false

let binding_base_url_is_loopback binding =
  match binding_endpoint_url binding with
  | None -> false
  | Some base_url ->
      Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt

let binding_is_local_runtime (binding : Runtime_binding.t) =
  match binding.Runtime_binding.transport with
  | Runtime_binding.Cli -> false
  | Runtime_binding.Http | Runtime_binding.Managed | Runtime_binding.Custom_openai_compat ->
      binding_auth_is_no_auth binding && binding_base_url_is_loopback binding

let local_runtime_provider_id () =
  Runtime_binding.all ()
  |> List.find_opt binding_is_local_runtime
  |> Option.map (fun binding -> binding.Runtime_binding.id)

let provider_label_of_config (cfg : Llm_provider.Provider_config.t) =
  match Runtime_binding.binding_for_provider_config cfg with
  | Some binding -> binding.Runtime_binding.id
  | None -> Llm_provider.Provider_registry.provider_name_of_config cfg

let provider_health_key_of_config (cfg : Llm_provider.Provider_config.t) =
  match cfg.kind with
  | Llm_provider.Provider_config.OpenAI_compat
    when Llm_provider.Provider_config.is_local cfg ->
      let base_url = String.trim cfg.base_url in
      if String.equal base_url ""
      then provider_label_of_config cfg
      else Printf.sprintf "%s:%s@%s" (provider_label_of_config cfg) cfg.model_id base_url
  | _ -> provider_label_of_config cfg

let provider_model_health_key_of_config cfg =
  Printf.sprintf "%s:%s" (provider_health_key_of_config cfg) cfg.model_id

let display_provider_name_of_config cfg = provider_label_of_config cfg

let model_label_of_config cfg =
  Printf.sprintf "%s:%s" (display_provider_name_of_config cfg) cfg.model_id

let provider_model_label provider model =
  if String.equal model "" then None else Some (Printf.sprintf "%s:%s" provider model)

let provider_name_of_kind (kind : Llm_provider.Provider_config.provider_kind) =
  let cfg =
    Llm_provider.Provider_config.make ~kind ~model_id:"auto" ~base_url:"" ()
  in
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

let provider_label_of_model_label ?provider_kind model =
  let explicit =
    match provider_prefix_of_label model with
    | Some prefix -> provider_label_of_explicit_prefix prefix
    | None -> None
  in
  match explicit, provider_kind with
  | Some provider, _ -> provider
  | None, Some kind -> provider_label_of_provider_kind kind
  | None, None -> unknown_runtime_label

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
      let base_url = registry_default_base_url provider_name in
      Some (cfg_of_kind ~kind ~model_id ~base_url)
  | Custom_url { model_id; base_url } ->
      Some
        (cfg_of_kind
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id
           ~base_url)
  | Unknown _ -> None

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
  Cascade_http_probe_url.of_provider_config cfg

let of_provider_config provider_cfg =
  let health_key = provider_health_key_of_config provider_cfg in
  let model_health_key = provider_model_health_key_of_config provider_cfg in
  { provider_cfg
  ; health_key
  ; model_health_key
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
  | Some label_runtime_id ->
      String.equal (String.trim label_runtime_id) (String.trim runtime_id)
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

let provider_label_of_runtime_label ?provider_kind label =
  provider_label_of_model_label ?provider_kind label

let is_structurally_unmetered_runtime_provider provider =
  match runtime_binding_of_label provider with
  | Some binding ->
      binding.Runtime_binding.transport = Runtime_binding.Cli
      || not binding.Runtime_binding.capabilities.emits_usage_tokens
  | None -> false

let canonical_provider_of_label label =
  match String.index_opt label ':' with
  | Some idx when idx > 0 ->
      String.sub label 0 idx
      |> String.trim
      |> runtime_binding_of_label
      |> Option.map (fun binding -> binding.Runtime_binding.id)
  | _ -> runtime_binding_of_label label |> Option.map (fun binding -> binding.Runtime_binding.id)

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
        (match runtime_binding_of_label active with
         | Some binding ->
             let matches_provider label =
               canonical_provider_of_label label = Some binding.Runtime_binding.id
             in
             (match List.find_opt matches_provider configured_labels with
              | Some label -> label
              | None ->
                let runtime_id =
                  match binding.Runtime_binding.default_model with
                  | Some value when String.trim value <> "" -> value
                  | _ -> "auto"
                in
                provider_model_label binding.Runtime_binding.id runtime_id
                |> Option.value ~default:active)
         | None -> active)

let runtime_health_key_of_label label =
  provider_config_of_runtime_label label |> Option.map provider_health_key_of_config

let runtime_health_keys_of_labels labels =
  labels
  |> List.filter_map runtime_health_key_of_label
  |> List.sort_uniq String.compare

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
let provider_label candidate =
  provider_label_of_model_label
    ~provider_kind:candidate.provider_cfg.kind
    (model_label_of_config candidate.provider_cfg)

let health_keys candidate =
  if String.equal candidate.health_key candidate.model_health_key then
    [ candidate.health_key ]
  else
    [ candidate.health_key; candidate.model_health_key ]

let first_health_cooldown candidate =
  health_keys candidate
  |> List.find_map (fun provider_key ->
    match
      Cascade_health_tracker.check_circuit_breaker
        Cascade_health_tracker.global
        ~provider_key
    with
    | Ok () -> None
    | Error msg -> Some (provider_key, msg))

let has_recovery_evidence candidate =
  health_keys candidate
  |> List.exists (fun provider_key ->
    match
      Cascade_health_tracker.provider_info
        Cascade_health_tracker.global
        ~provider_key
    with
    | None -> false
    | Some info ->
      (not info.in_cooldown)
      && (info.events_in_window > 0 || info.latency_samples > 0)
      && info.success_rate > 0.0)

let effective_attempt_timeout_s ~is_last:_ ~configured_timeout_s _candidate =
  configured_timeout_s

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
  { health_key; capacity_key }

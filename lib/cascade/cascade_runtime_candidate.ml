module Binding = Agent_sdk.Provider_runtime_binding
module PConfig = Llm_provider.Provider_config

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed

let normalize_label value = value |> String.trim |> String.lowercase_ascii

let binding_id (binding : Binding.t) = binding.Binding.id

let find_binding_by_candidates candidates =
  let rec loop = function
    | [] -> None
    | candidate :: rest ->
      (match trim_nonempty candidate with
       | None -> loop rest
       | Some label ->
         (match Binding.find label with
          | Some _ as binding -> binding
          | None -> loop rest))
  in
  loop candidates

let find_unique_binding_by_kind kind =
  match List.filter (fun (binding : Binding.t) -> binding.Binding.kind = kind) (Binding.all ()) with
  | [ binding ] -> Some binding
  | [] | _ :: _ :: _ -> None

let endpoint_url (binding : Binding.t) = trim_nonempty binding.Binding.base_url

let auth_is_no_auth (binding : Binding.t) =
  match binding.Binding.auth with
  | Binding.No_auth -> true
  | Binding.Api_key_env _
  | Binding.Cli_cached_login
  | Binding.Oauth_cached_login
  | Binding.Setup_token_env _
  | Binding.File _
  | Binding.Exec _ -> false

let binding_labels (binding : Binding.t) =
  binding.Binding.id :: binding.Binding.aliases
  |> List.filter_map trim_nonempty
  |> List.map normalize_label

let binding_has_label binding expected =
  let expected = normalize_label expected in
  List.exists (String.equal expected) (binding_labels binding)

let binding_base_url_is_loopback binding =
  match endpoint_url binding with
  | None -> false
  | Some base_url -> Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt

let is_local_binding binding =
  match binding.Binding.kind with
  | PConfig.Ollama -> auth_is_no_auth binding && binding_base_url_is_loopback binding
  | PConfig.OpenAI_compat ->
    auth_is_no_auth binding
    && (binding_base_url_is_loopback binding || binding_has_label binding "llama")
  | PConfig.Anthropic
  | PConfig.Kimi
  | PConfig.Glm
  | PConfig.DashScope
  | PConfig.Gemini
  | PConfig.Claude_code
  | PConfig.Codex_cli
  | PConfig.Gemini_cli
  | PConfig.Kimi_cli -> false

let runtime_kind_of_binding binding =
  match binding.Binding.transport with
  | Binding.Cli -> `Cli_agent
  | Binding.Http | Binding.Managed | Binding.Custom_openai_compat ->
    if is_local_binding binding then `Local else `Direct_api

let local_binding () =
  match find_binding_by_candidates [ "llama" ] with
  | Some binding when runtime_kind_of_binding binding = `Local -> Some binding
  | Some _ | None ->
    Binding.all () |> List.find_opt (fun binding -> runtime_kind_of_binding binding = `Local)

let local_model_label model_id =
  let provider =
    match local_binding () with
    | Some binding -> binding_id binding
    | None -> "llama"
  in
  provider ^ ":" ^ model_id

let default_local_runtime_label_from_binding () =
  match local_binding () with
  | Some binding -> binding_id binding ^ ":auto"
  | None -> "auto"

let default_binding_model_id binding = Option.bind binding.Binding.default_model trim_nonempty

let binding_supports_runtime_mcp_http_headers (binding : Binding.t) =
  let caps = binding.Binding.capabilities in
  let runtime_mcp_caps =
    caps.supports_runtime_mcp_tools || caps.supports_runtime_tool_events
  in
  match binding.Binding.kind with
  | PConfig.Codex_cli | PConfig.Gemini_cli -> false
  | _ ->
    runtime_mcp_caps
    || (binding.Binding.transport = Binding.Cli && caps.supports_tools)

let http_probe_capable_kind (kind : PConfig.provider_kind) =
  match kind with
  | PConfig.Ollama -> true
  | PConfig.Anthropic
  | PConfig.Claude_code
  | PConfig.OpenAI_compat
  | PConfig.Glm
  | PConfig.DashScope
  | PConfig.Codex_cli
  | PConfig.Gemini
  | PConfig.Gemini_cli
  | PConfig.Kimi
  | PConfig.Kimi_cli -> false

let provider_label_of_kind kind =
  let cfg = PConfig.make ~kind ~model_id:"auto" ~base_url:"" () in
  Llm_provider.Provider_registry.provider_name_of_config cfg

let provider_label_of_config cfg =
  match Binding.binding_for_provider_config cfg with
  | Some binding -> binding_id binding
  | None -> Llm_provider.Provider_registry.provider_name_of_config cfg

let provider_health_key_of_config (cfg : PConfig.t) =
  let provider_label = provider_label_of_config cfg in
  match cfg.kind with
  | PConfig.OpenAI_compat when PConfig.is_local cfg ->
    let base_url = String.trim cfg.base_url in
    if String.equal base_url ""
    then provider_label
    else Printf.sprintf "%s:%s@%s" provider_label cfg.model_id base_url
  | _ -> provider_label

let provider_model_health_key_of_config cfg =
  Printf.sprintf "%s:%s" (provider_health_key_of_config cfg) cfg.PConfig.model_id

let provider_prefix_of_label label =
  match String.index_opt label ':' with
  | None -> None
  | Some idx ->
    if idx = 0 || idx >= String.length label - 1
    then None
    else Some (String.sub label 0 idx |> normalize_label)

let binding_for_model_label ?provider_kind label =
  match provider_prefix_of_label label with
  | Some "custom" -> None
  | Some prefix -> find_binding_by_candidates [ prefix ]
  | None ->
    (match find_binding_by_candidates [ label ], provider_kind with
     | Some binding, _ -> Some binding
     | None, Some kind -> find_unique_binding_by_kind kind
     | None, None -> None)

let provider_label_of_model_label ?provider_kind label =
  match provider_prefix_of_label label with
  | Some "custom" -> "custom"
  | Some _ ->
    (match binding_for_model_label ?provider_kind label with
     | Some binding -> binding_id binding
     | None -> "unknown")
  | None ->
    (match binding_for_model_label ?provider_kind label, provider_kind with
     | Some binding, _ -> binding_id binding
     | None, Some kind -> provider_label_of_kind kind
     | None, None -> "unknown")

let supports_runtime_mcp_http_headers_for_model_label ?provider_kind label =
  match binding_for_model_label ?provider_kind label with
  | Some binding -> binding_supports_runtime_mcp_http_headers binding
  | None -> false

let usage_missing_by_design_for_provider provider =
  match find_binding_by_candidates [ provider ] with
  | Some binding -> not binding.Binding.capabilities.emits_usage_tokens
  | None -> false

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
  if http_probe_capable_kind cfg.kind && cfg.base_url <> ""
  then Some cfg.base_url
  else None

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

let registry_default_base_url provider_name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry provider_name with
  | Some entry -> entry.defaults.base_url
  | None -> ""

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

let default_local_runtime_label = default_local_runtime_label_from_binding

let local_runtime_label = local_model_label

let labels_require_runtime_mcp_header_sync labels =
  List.exists supports_runtime_mcp_http_headers_for_model_label labels

let unknown_runtime_label = "unknown_provider"

let provider_label_of_runtime_label ?provider_kind label =
  provider_label_of_model_label ?provider_kind label

let is_structurally_unmetered_runtime_provider provider =
  usage_missing_by_design_for_provider provider

let canonical_provider_of_label label =
  match String.index_opt label ':' with
  | Some idx when idx > 0 ->
      let prefix = String.sub label 0 idx |> String.trim in
      find_binding_by_candidates [ prefix ] |> Option.map binding_id
  | _ ->
      find_binding_by_candidates [ label ] |> Option.map binding_id

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
        (match find_binding_by_candidates [ active ] with
         | Some binding ->
             let matches_provider label =
               canonical_provider_of_label label
               = Some (binding_id binding)
             in
             (match List.find_opt matches_provider configured_labels with
              | Some label -> label
              | None ->
                let runtime_id =
                  match default_binding_model_id binding with
                  | Some value when String.trim value <> "" -> value
                  | _ -> "auto"
                in
                Printf.sprintf "%s:%s" (binding_id binding) runtime_id)
         | None -> active)

let runtime_health_key_of_label label =
  let cfg_of_kind ~kind ~model_id ~base_url =
    Llm_provider.Provider_config.make ~kind ~model_id ~base_url ()
  in
  let cfg =
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
  in
  Option.map provider_health_key_of_config cfg

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
let provider_label candidate = provider_label_of_config candidate.provider_cfg

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
  { health_key; capacity_key; weight = (fun _ -> 1) }

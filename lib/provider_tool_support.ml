type capabilities = {
  supports_inline_tools : bool;
  supports_inline_tool_choice : bool;
  supports_runtime_mcp_tools : bool;
  supports_runtime_tool_events : bool;
  supports_runtime_mcp_http_headers : bool;
}

let normalize_cli_provider_caps
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (caps : Llm_provider.Capabilities.capabilities) =
  match provider_cfg.kind with
  | Llm_provider.Provider_config.Kimi_cli ->
      {
        caps with
        supports_tools = false;
        supports_runtime_mcp_tools = true;
        supports_runtime_tool_events = true;
      }
  | _ -> caps

let oas_capabilities_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let base_caps =
    match provider_cfg.kind with
    | Llm_provider.Provider_config.Ollama ->
        Llm_provider.Capabilities.ollama_capabilities
    | Anthropic -> Llm_provider.Capabilities.anthropic_capabilities
    | Kimi -> Llm_provider.Capabilities.kimi_capabilities
    | Glm -> Llm_provider.Capabilities.glm_capabilities
    | Gemini -> Llm_provider.Capabilities.gemini_capabilities
    | OpenAI_compat -> Llm_provider.Capabilities.openai_chat_capabilities
    | Claude_code -> Llm_provider.Capabilities.claude_code_capabilities
    | Gemini_cli -> Llm_provider.Capabilities.gemini_cli_capabilities
    | Kimi_cli -> Llm_provider.Capabilities.kimi_cli_capabilities
    | Codex_cli -> Llm_provider.Capabilities.codex_cli_capabilities
  in
  let caps =
    match provider_cfg.kind with
    | Llm_provider.Provider_config.Claude_code
    | Gemini_cli
    | Kimi_cli
    | Codex_cli -> base_caps
    | _ -> (
        match Llm_provider.Capabilities.for_model_id provider_cfg.model_id with
        | Some caps -> caps
        | None -> base_caps)
  in
  let caps = normalize_cli_provider_caps ~provider_cfg caps in
  match provider_cfg.supports_tool_choice_override with
  | Some supports_tool_choice -> { caps with supports_tool_choice }
  | None -> caps

let supports_runtime_mcp_http_headers
    (provider_cfg : Llm_provider.Provider_config.t) =
  match provider_cfg.kind with
  | Llm_provider.Provider_config.Claude_code
  | Kimi_cli ->
      true
  | Codex_cli
  | Gemini_cli
  | Anthropic
  | OpenAI_compat
  | Ollama
  | Gemini
  | Glm
  | Kimi ->
      false

let capabilities_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = oas_capabilities_of_config provider_cfg in
  {
    supports_inline_tools = caps.supports_tools;
    supports_inline_tool_choice = caps.supports_tools && caps.supports_tool_choice;
    supports_runtime_mcp_tools = caps.supports_runtime_mcp_tools;
    supports_runtime_tool_events = caps.supports_runtime_tool_events;
    supports_runtime_mcp_http_headers =
      supports_runtime_mcp_http_headers provider_cfg;
  }

let provider_supports_inline_tools (provider_cfg : Llm_provider.Provider_config.t) =
  (capabilities_of_config provider_cfg).supports_inline_tools

let provider_supports_runtime_mcp_lane
    (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = capabilities_of_config provider_cfg in
  caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events

let runtime_mcp_policy_requires_http_headers
    (policy : Llm_provider.Llm_transport.runtime_mcp_policy) =
  List.exists
    (function
      | Llm_provider.Llm_transport.Http_server { headers = _ :: _; _ } -> true
      | _ -> false)
    policy.servers

let provider_supports_runtime_mcp_policy
    (provider_cfg : Llm_provider.Provider_config.t)
    (policy : Llm_provider.Llm_transport.runtime_mcp_policy) =
  let caps = capabilities_of_config provider_cfg in
  caps.supports_runtime_mcp_tools
  && caps.supports_runtime_tool_events
  &&
  ((not (runtime_mcp_policy_requires_http_headers policy))
  || caps.supports_runtime_mcp_http_headers)

let supports_required_tool_use ?runtime_mcp_policy
    ~require_tool_choice_support ~require_tool_support
    (provider_cfg : Llm_provider.Provider_config.t) =
  if not require_tool_choice_support && not require_tool_support then
    true
  else
    let caps = capabilities_of_config provider_cfg in
    let runtime_mcp =
      match runtime_mcp_policy with
      | Some policy -> provider_supports_runtime_mcp_policy provider_cfg policy
      | None -> caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events
    in
    match require_tool_choice_support, require_tool_support with
    | true, true -> caps.supports_inline_tool_choice || runtime_mcp
    | true, false -> caps.supports_inline_tool_choice
    | false, true -> caps.supports_inline_tools || runtime_mcp
    | false, false -> true

let provider_debug_label (cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    cfg.model_id

let apply_required_tool_use_filter ?runtime_mcp_policy
    ~require_tool_choice_support ~require_tool_support ~label
    (providers : Llm_provider.Provider_config.t list) =
  if not require_tool_choice_support && not require_tool_support then
    providers
  else
    let filtered =
      List.filter
        (supports_required_tool_use ?runtime_mcp_policy
           ~require_tool_choice_support ~require_tool_support)
        providers
    in
    if filtered = [] && providers <> [] then (
      let runtime_mcp_http_headers =
        match runtime_mcp_policy with
        | Some policy -> runtime_mcp_policy_requires_http_headers policy
        | None -> false
      in
      Log.Misc.warn
        "cascade %s: required tool-use gate removed all providers (providers=[%s], runtime_mcp_http_headers=%b)"
        label
        (String.concat ", " (List.map provider_debug_label providers))
        runtime_mcp_http_headers);
    filtered

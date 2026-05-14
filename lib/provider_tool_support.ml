module Binding = Agent_sdk.Provider_runtime_binding
module PConfig = Llm_provider.Provider_config

type capabilities =
  { supports_inline_tools : bool
  ; supports_inline_tool_choice : bool
  ; supports_runtime_mcp_tools : bool
  ; supports_runtime_tool_events : bool
  ; supports_runtime_mcp_http_headers : bool
  }

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let normalize_label value = value |> String.trim |> String.lowercase_ascii

(** Whether the resolved provider adapter is a CLI runtime (Claude Code,
    Codex CLI, Gemini CLI, Kimi CLI).  MASC uses this only for local
    tool-delivery projection after OAS has resolved provider/model
    capabilities. *)
let is_cli_agent_provider (provider_cfg : Llm_provider.Provider_config.t) =
  Llm_provider.Provider_config.is_subprocess_cli provider_cfg.kind
;;

(** [normalize_cli_caps_when ~is_cli caps] overrides CLI runtime caps when
    [is_cli] is [true]. Decoupled from [is_cli_agent_provider] so callers
    that have already resolved the adapter (e.g. [oas_capabilities_of_config]
    below) can avoid re-resolving for the same provider.

    Override semantics: CLI providers (Claude Code, Codex CLI, Gemini CLI,
    Kimi CLI) do not expose inline function-calling to this gate. Runtime MCP
    support remains adapter/OAS-owned because not every CLI can consume
    request-scoped MCP policy; Gemini CLI is the known false case. *)
let normalize_cli_caps_when ~is_cli (caps : Llm_provider.Capabilities.capabilities) =
  if is_cli
  then { caps with supports_tools = false; supports_tool_choice = false }
  else caps
;;

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
;;

let binding_endpoint_url (binding : Binding.t) = trim_nonempty binding.Binding.base_url

let binding_auth_is_no_auth (binding : Binding.t) =
  match binding.Binding.auth with
  | Binding.No_auth -> true
  | Binding.Api_key_env _
  | Binding.Cli_cached_login
  | Binding.Oauth_cached_login
  | Binding.Setup_token_env _
  | Binding.File _
  | Binding.Exec _ -> false
;;

let binding_labels (binding : Binding.t) =
  binding.Binding.id :: binding.Binding.aliases
  |> List.filter_map trim_nonempty
  |> List.map normalize_label
;;

let binding_has_label binding expected =
  let expected = normalize_label expected in
  List.exists (String.equal expected) (binding_labels binding)
;;

let binding_base_url_is_loopback binding =
  match binding_endpoint_url binding with
  | None -> false
  | Some base_url -> Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let binding_is_local binding =
  match binding.Binding.kind with
  | PConfig.Ollama -> binding_auth_is_no_auth binding && binding_base_url_is_loopback binding
  | PConfig.OpenAI_compat ->
    binding_auth_is_no_auth binding
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
;;

let binding_is_direct_api binding =
  match binding.Binding.transport with
  | Binding.Cli -> false
  | Binding.Http | Binding.Managed | Binding.Custom_openai_compat ->
    not (binding_is_local binding)
;;

let binding_uses_anthropic_caching (binding : Binding.t) =
  binding.Binding.capabilities.supports_prompt_caching
  || binding.Binding.capabilities.supports_caching
;;

let binding_requires_per_keeper_bridging (binding : Binding.t) =
  match binding.Binding.command, binding.Binding.kind with
  | Some "codex", _ | _, PConfig.Codex_cli -> true
  | _ -> false
;;

let binding_tolerates_bound_actor_fallback binding =
  (not (binding_requires_per_keeper_bridging binding))
  &&
  (binding_supports_runtime_mcp_http_headers binding
   || not (binding_is_direct_api binding))
;;

let binding_for_config provider_cfg =
  Binding.binding_for_provider_config provider_cfg
;;

let binding_for_kind kind =
  match List.filter (fun (binding : Binding.t) -> binding.Binding.kind = kind) (Binding.all ()) with
  | [ binding ] -> Some binding
  | [] | _ :: _ :: _ -> None
;;

let supports_runtime_mcp_http_headers (provider_cfg : Llm_provider.Provider_config.t) =
  match binding_for_config provider_cfg with
  | Some binding -> binding_supports_runtime_mcp_http_headers binding
  | None -> false
;;

let requires_per_keeper_bridging_for_bound_actor_tools
      (provider_cfg : Llm_provider.Provider_config.t)
  =
  match binding_for_config provider_cfg with
  | Some binding -> binding_requires_per_keeper_bridging binding
  | None -> provider_cfg.kind = PConfig.Codex_cli
;;

let requires_per_keeper_bridging_for_bound_actor_tools_for_kind kind =
  match binding_for_kind kind with
  | Some binding -> binding_requires_per_keeper_bridging binding
  | None -> kind = PConfig.Codex_cli
;;

let tolerates_bound_actor_fallback_for_kind kind =
  match binding_for_kind kind with
  | Some binding -> binding_tolerates_bound_actor_fallback binding
  | None -> false
;;

let uses_anthropic_caching_for_kind kind =
  match binding_for_kind kind with
  | Some binding -> binding_uses_anthropic_caching binding
  | None -> false
;;

let auth_env_keys_for_kind (kind : PConfig.provider_kind) =
  match kind with
  | PConfig.OpenAI_compat -> [ "OPENAI_API_KEY" ]
  | PConfig.Kimi -> [ "KIMI_API_KEY_SB"; "KIMI_API_KEY" ]
  | PConfig.Gemini -> [ "GOOGLE_CLOUD_PROJECT"; "GOOGLE_CLOUD_LOCATION" ]
  | _ -> Option.to_list (PConfig.default_api_key_env kind)
;;

(** Resolve OAS-level capabilities for a provider config, then apply only
    MASC's tool-delivery projection for CLI runtimes.  Provider/model/catalog
    capability truth stays in OAS. *)
let oas_capabilities_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let is_cli = is_cli_agent_provider provider_cfg in
  let caps =
    Agent_sdk.Provider_runtime_binding.capabilities_for_provider_config provider_cfg
  in
  if is_cli
  then
    let runtime_mcp_lane =
      supports_runtime_mcp_http_headers provider_cfg
      || requires_per_keeper_bridging_for_bound_actor_tools provider_cfg
    in
    { (normalize_cli_caps_when ~is_cli caps) with
      supports_runtime_mcp_tools = runtime_mcp_lane
    ; supports_runtime_tool_events = runtime_mcp_lane
    }
  else caps
;;

let capabilities_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = oas_capabilities_of_config provider_cfg in
  { supports_inline_tools = caps.supports_tools
  ; supports_inline_tool_choice = caps.supports_tools && caps.supports_tool_choice
  ; supports_runtime_mcp_tools = caps.supports_runtime_mcp_tools
  ; supports_runtime_tool_events = caps.supports_runtime_tool_events
  ; supports_runtime_mcp_http_headers = supports_runtime_mcp_http_headers provider_cfg
  }
;;

let provider_supports_inline_tools (provider_cfg : Llm_provider.Provider_config.t) =
  (capabilities_of_config provider_cfg).supports_inline_tools
;;

let provider_supports_runtime_mcp_lane (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = capabilities_of_config provider_cfg in
  caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events
;;

let runtime_mcp_policy_requires_http_headers
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  List.exists
    (function
      | Llm_provider.Llm_transport.Http_server { headers = _ :: _; _ } -> true
      | _ -> false)
    policy.servers
;;

let provider_supports_runtime_mcp_http_header
      (provider_cfg : Llm_provider.Provider_config.t)
      key
  =
  (* General HTTP-header support OR the Codex identity-header carve-out.
     The identity carve-out covers `x-masc-*` routing labels and other
     non-secret headers declared by the MASC local runtime policy.
     [Authorization] is NOT carried here: it is handled separately by
     [provider_supports_bridged_authorization_header] below, which requires
     both adapter-level per-keeper bridging and the x-masc-agent-name /
     x-masc-keeper-name identity headers to be present on the same request. *)
  supports_runtime_mcp_http_headers provider_cfg
  ||
  (requires_per_keeper_bridging_for_bound_actor_tools provider_cfg
   &&
   match String.lowercase_ascii (String.trim key) with
   | "authorization" | "x-masc-agent-name" | "x-masc-keeper-name" -> true
   | _ -> false)
;;

let header_key_present headers key =
  let wanted = String.lowercase_ascii (String.trim key) in
  List.exists
    (fun (candidate, _) ->
      String.equal wanted (String.lowercase_ascii (String.trim candidate)))
    headers
;;

let provider_supports_bridged_authorization_header provider_cfg headers key =
  String.equal "authorization" (String.lowercase_ascii (String.trim key))
  && requires_per_keeper_bridging_for_bound_actor_tools provider_cfg
  && header_key_present headers "x-masc-agent-name"
  && header_key_present headers "x-masc-keeper-name"
;;

let runtime_mcp_policy_requires_unsupported_http_headers
      (provider_cfg : Llm_provider.Provider_config.t)
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  List.exists
    (function
      | Llm_provider.Llm_transport.Http_server { headers; _ } ->
        List.exists
          (fun (key, _) ->
             not
               (provider_supports_runtime_mcp_http_header provider_cfg key
                || provider_supports_bridged_authorization_header
                     provider_cfg
                     headers
                     key))
          headers
      | _ -> false)
    policy.servers
;;

let provider_supports_runtime_mcp_policy
      (provider_cfg : Llm_provider.Provider_config.t)
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  let caps = capabilities_of_config provider_cfg in
  caps.supports_runtime_mcp_tools
  && caps.supports_runtime_tool_events
  && not (runtime_mcp_policy_requires_unsupported_http_headers provider_cfg policy)
;;

let supports_required_tool_use
      ?runtime_mcp_policy
      ~require_tool_choice_support
      ~require_tool_support
      (provider_cfg : Llm_provider.Provider_config.t)
  =
  if (not require_tool_choice_support) && not require_tool_support
  then true
  else (
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
    | false, false -> true)
;;

(* #10474: when [supports_required_tool_use] returns false, attribute
   the rejection to the most actionable single cause so dashboards
   can show "5 codex_cli + 1 kimi_cli rejected for
   runtime_mcp_http_headers_required" instead of a flat counter.

   Priority order (most-specific first):
   1. [runtime_mcp_http_headers_required] — runtime_mcp caps are
      present but the policy demands HTTP headers and the provider
      does not support them. This is the #10474 case; operator can
      either swap to stdio MCP or pick header-capable providers.
   2. [runtime_mcp_caps_missing] — provider lacks
      [supports_runtime_mcp_tools] or [supports_runtime_tool_events].
      Inline path was also unavailable; cascade authoring problem.
   3. [inline_tool_choice_unsupported] — only [require_tool_choice]
      mode and provider has no [supports_inline_tool_choice].
   4. [inline_tools_unsupported] — only [require_tool_support] mode
      and provider has no [supports_inline_tools].
   5. [filter_disabled] — both [require_*] flags false, no rejection
      should occur; emitted only as a defensive default.

   Returns [None] when the provider passes the filter; classification
   is only meaningful for the rejection path. *)
type rejection_reason =
  | Runtime_mcp_http_headers_required
  | Runtime_mcp_caps_missing
  | Inline_tool_choice_unsupported
  | Inline_tools_unsupported
  | Filter_disabled

let rejection_reason_label = function
  | Runtime_mcp_http_headers_required -> "runtime_mcp_http_headers_required"
  | Runtime_mcp_caps_missing -> "runtime_mcp_caps_missing"
  | Inline_tool_choice_unsupported -> "inline_tool_choice_unsupported"
  | Inline_tools_unsupported -> "inline_tools_unsupported"
  | Filter_disabled -> "filter_disabled"
;;

let classify_rejection
      ?runtime_mcp_policy
      ~require_tool_choice_support
      ~require_tool_support
      (provider_cfg : Llm_provider.Provider_config.t)
  =
  if (not require_tool_choice_support) && not require_tool_support
  then None
  else if
    supports_required_tool_use
      ?runtime_mcp_policy
      ~require_tool_choice_support
      ~require_tool_support
      provider_cfg
  then None
  else (
    let caps = capabilities_of_config provider_cfg in
    let runtime_mcp_caps_ok =
      caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events
    in
    let runtime_mcp_blocked_by_headers =
      runtime_mcp_caps_ok
      &&
      match runtime_mcp_policy with
      | Some policy ->
        runtime_mcp_policy_requires_unsupported_http_headers provider_cfg policy
      | None -> false
    in
    let inline_path_ok =
      match require_tool_choice_support, require_tool_support with
      | true, _ -> caps.supports_inline_tool_choice
      | false, true -> caps.supports_inline_tools
      | false, false -> true
    in
    if runtime_mcp_blocked_by_headers && not inline_path_ok
    then Some Runtime_mcp_http_headers_required
    else if (not runtime_mcp_caps_ok) && not inline_path_ok
    then Some Runtime_mcp_caps_missing
    else if
      require_tool_choice_support
      && (not caps.supports_inline_tool_choice)
      && not runtime_mcp_caps_ok
    then Some Inline_tool_choice_unsupported
    else if
      require_tool_support && (not caps.supports_inline_tools) && not runtime_mcp_caps_ok
    then Some Inline_tools_unsupported
    else Some Filter_disabled)
;;

let provider_debug_label (cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf
    "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    cfg.model_id
;;

let provider_kind_label (cfg : Llm_provider.Provider_config.t) =
  Llm_provider.Provider_config.string_of_provider_kind cfg.kind
;;

(* #10474: emit a Prometheus counter per rejected provider so
   operators can see which rejection reason dominates per cascade.
   Cardinality: cascades × provider_kinds × ~5 reasons; bounded by
   the small set of cascade names actually configured (~10) and
   provider kinds (~10). *)
let cascade_filter_rejection_metric = "masc_cascade_filter_rejection_total"

let record_filter_rejection ~cascade ~provider_cfg ~reason =
  Prometheus.inc_counter
    cascade_filter_rejection_metric
    ~labels:
      [ "cascade", cascade
      ; "provider_kind", provider_kind_label provider_cfg
      ; "reason", rejection_reason_label reason
      ]
    ()
;;

let apply_required_tool_use_filter
      ?runtime_mcp_policy
      ~require_tool_choice_support
      ~require_tool_support
      ~label
      (providers : Llm_provider.Provider_config.t list)
  =
  if (not require_tool_choice_support) && not require_tool_support
  then providers
  else (
    let kept, rejected =
      List.partition
        (supports_required_tool_use
           ?runtime_mcp_policy
           ~require_tool_choice_support
           ~require_tool_support)
        providers
    in
    (* #10474: emit per-provider rejection observability so dashboards
       can attribute "cascade dead" events to a specific cause. The
       all-providers-removed warn line below kept for human-readable
       logs; counter is the machine-consumable signal. *)
    List.iter
      (fun provider_cfg ->
         match
           classify_rejection
             ?runtime_mcp_policy
             ~require_tool_choice_support
             ~require_tool_support
             provider_cfg
         with
         | Some reason -> record_filter_rejection ~cascade:label ~provider_cfg ~reason
         | None -> ())
      rejected;
    if kept = [] && providers <> []
    then (
      let runtime_mcp_http_headers =
        match runtime_mcp_policy with
        | Some policy -> runtime_mcp_policy_requires_http_headers policy
        | None -> false
      in
      Log.Misc.warn
        "cascade %s: required tool-use gate removed all providers (providers=[%s], \
         runtime_mcp_http_headers=%b)"
        label
        (String.concat ", " (List.map provider_debug_label providers))
        runtime_mcp_http_headers);
    kept)
;;

type capabilities =
  { supports_inline_tools : bool
  ; supports_inline_tool_choice : bool
  ; supports_runtime_mcp_tools : bool
  ; supports_runtime_tool_events : bool
  ; supports_runtime_mcp_http_headers : bool
  }

(** Whether the resolved provider adapter is a CLI runtime (Claude Code,
    Codex CLI, Gemini CLI, Kimi CLI).  Capability normalisation and the
    [for_model_id] bypass both key off this predicate rather than matching
    on [Provider_config.provider_kind] (RFC-0058 §2.4). *)
let is_cli_agent_provider (provider_cfg : Llm_provider.Provider_config.t) =
  match Provider_adapter.adapter_of_provider_config provider_cfg with
  | Some adapter -> adapter.runtime_kind = Provider_adapter.Cli_agent
  | None -> false
;;

(** CLI providers (Claude Code, Kimi CLI, Gemini CLI, Codex CLI) use runtime
    MCP for tool invocation, not inline function-calling.  The OAS base
    capabilities for CLI kinds may disagree on [supports_runtime_mcp_tools]
    (e.g. Gemini CLI defaults to [false] in OAS despite supporting MCP via
    its --mcp-config flag).  Normalize all CLI runtimes to the same
    contract: disable inline tools, enable runtime MCP. *)
let normalize_cli_provider_caps
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (caps : Llm_provider.Capabilities.capabilities)
  =
  if is_cli_agent_provider provider_cfg
  then
    { caps with
      supports_tools = false
    ; supports_tool_choice = false
    ; supports_runtime_mcp_tools = true
    ; supports_runtime_tool_events = true
    }
  else caps
;;

(** Resolve OAS-level capabilities for a provider config.

    CLI runtimes (Claude_code, Gemini_cli, Kimi_cli, Codex_cli) bypass
    [for_model_id] because the CLI tool selects the underlying model
    internally — the model_id in the config is a routing hint, not an
    API model identifier that OAS can look up.  All other adapters consult
    [for_model_id] first, falling back to the kind-level base. *)
let oas_capabilities_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = Provider_adapter.oas_capabilities_of_config provider_cfg in
  let caps =
    if is_cli_agent_provider provider_cfg
    then caps
    else (
      match Llm_provider.Capabilities.for_model_id provider_cfg.model_id with
      | Some override -> override
      | None -> caps)
  in
  let caps = normalize_cli_provider_caps ~provider_cfg caps in
  match provider_cfg.supports_tool_choice_override with
  | Some supports_tool_choice -> { caps with supports_tool_choice }
  | None -> caps
;;

let supports_runtime_mcp_http_headers (provider_cfg : Llm_provider.Provider_config.t) =
  Provider_adapter.supports_runtime_mcp_http_headers_for_config provider_cfg
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
  (* General HTTP-header support OR adapter-specific identity-header
     carve-out (e.g. Codex CLI carries [Authorization]/[x-masc-*] via
     [bearer_token_env_var] + non-secret routing labels).  The carve-out
     set lives on the adapter row, not in this consumer module. *)
  Provider_adapter.accepts_runtime_mcp_http_header_for_config provider_cfg key
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
             not (provider_supports_runtime_mcp_http_header provider_cfg key))
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

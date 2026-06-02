type capabilities =
  { supports_inline_tools : bool
  ; supports_inline_tool_choice : bool
  ; supports_runtime_mcp_tools : bool
  ; supports_runtime_tool_events : bool
  ; supports_runtime_mcp_http_headers : bool
  }

type runtime_capabilities_override =
  { supports_inline_tools : bool option
  ; supports_inline_tool_choice : bool option
  ; supports_runtime_mcp_tools : bool option
  ; supports_runtime_tool_events : bool option
  ; supports_runtime_mcp_http_headers : bool option
  }

type tool_policy =
  { supports_runtime_mcp_http_headers : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
  ; identity_runtime_mcp_header_keys : string list
  ; tolerates_bound_actor_fallback : bool
  }

module Runtime_binding = Agent_sdk.Provider_runtime_binding

let default_tool_policy =
  { supports_runtime_mcp_http_headers = false
  ; requires_per_keeper_bridging_for_bound_actor_tools = false
  ; identity_runtime_mcp_header_keys = []
  ; tolerates_bound_actor_fallback = false
  }
;;

let normalize_label label = String.trim label |> String.lowercase_ascii

let binding_supports_runtime_mcp_http_headers (binding : Runtime_binding.t) =
  match binding.Runtime_binding.transport with
  | Runtime_binding.Http
  | Runtime_binding.Managed -> false
;;

let fallback_tool_policy_for_config (provider_cfg : Llm_provider.Provider_config.t) =
  match Runtime_binding.binding_for_provider_config provider_cfg with
  | None -> default_tool_policy
  | Some binding ->
    let supports_headers = binding_supports_runtime_mcp_http_headers binding in
    { default_tool_policy with
      supports_runtime_mcp_http_headers = supports_headers
    ; tolerates_bound_actor_fallback =
        supports_headers
        ||
        (match binding.Runtime_binding.transport with
         | Runtime_binding.Http
         | Runtime_binding.Managed -> false)
    }
;;

(* RFC-0206: runtime-config tool-policy overrides removed. Under single-binding
   the binding-derived policy is the sole source. *)
let tool_policy_for_config provider_cfg = fallback_tool_policy_for_config provider_cfg
;;

let fallback_tool_policy_for_kind kind =
  let provider_cfg =
    Llm_provider.Provider_config.make ~kind ~model_id:"auto" ~base_url:"" ()
  in
  fallback_tool_policy_for_config provider_cfg
;;

let tool_policy_for_kind kind = fallback_tool_policy_for_kind kind
;;

(** Whether the resolved provider config is a CLI runtime (Claude Code,
    Codex CLI, Gemini CLI, Anthropic CLI).  MASC uses this only for local
    tool-delivery projection after OAS has resolved provider/model
    capabilities. *)
let is_cli_agent_provider (_provider_cfg : Llm_provider.Provider_config.t) =
  (* CLI subprocess provider kinds were removed in the agent_sdk pin bump;
     no provider kind is a subprocess CLI. *)
  false
;;

(** [normalize_cli_caps_when ~is_cli caps] overrides CLI runtime caps when
    [is_cli] is [true]. Decoupled from [is_cli_agent_provider] so callers
    that have already resolved the provider config (e.g.
    [oas_capabilities_of_config] below) can avoid re-resolving for the same
    provider.

    Override semantics: CLI providers (Claude Code, Codex CLI, Gemini CLI,
    Anthropic CLI) do not expose inline function-calling to this gate. Runtime MCP
    support remains keeper_runtime.toml/OAS-owned because not every CLI can consume
    request-scoped MCP policy; Gemini CLI is the known false case. *)
let normalize_cli_caps_when ~is_cli (caps : Llm_provider.Capabilities.capabilities) =
  if is_cli
  then { caps with supports_tools = false; supports_tool_choice = false }
  else caps
;;

(** Resolve OAS-level capabilities for a provider config, then merge
    declarative keeper_runtime.toml capabilities.  For CLI runtimes, the merge
    is unconditional (runtime MCP lane from tool policy).  For non-CLI
    runtimes, the merge applies when the declarative tool policy declares
    a runtime MCP lane — this ensures [classify_rejection] respects the
    operator's [supports-runtime-mcp-tools] even when the OAS model-level
    lookup returns a narrower capability set. *)
let oas_capabilities_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let is_cli = is_cli_agent_provider provider_cfg in
  let caps =
    Agent_sdk.Provider_runtime_binding.capabilities_for_provider_config provider_cfg
  in
  if is_cli
  then
    let tool_policy = tool_policy_for_config provider_cfg in
    let runtime_mcp_lane =
      tool_policy.supports_runtime_mcp_http_headers
      || tool_policy.requires_per_keeper_bridging_for_bound_actor_tools
    in
    { (normalize_cli_caps_when ~is_cli caps) with
      supports_runtime_mcp_tools = runtime_mcp_lane
    ; supports_runtime_tool_events = runtime_mcp_lane
    }
  else (
    (* Non-CLI providers: merge declarative keeper_runtime.toml capabilities
       so that [classify_rejection] respects the operator's declared
       [supports-runtime-mcp-tools] even when the OAS model-level
       lookup returns a narrower capability set. *)
    match tool_policy_for_config provider_cfg with
    | exception _ -> caps
    | tool_policy ->
      let runtime_mcp_lane =
        tool_policy.supports_runtime_mcp_http_headers
        || tool_policy.requires_per_keeper_bridging_for_bound_actor_tools
      in
      if runtime_mcp_lane
      then
        { caps with
          supports_runtime_mcp_tools = true
        ; supports_runtime_tool_events = true
        }
      else caps)
;;

let supports_runtime_mcp_http_headers (provider_cfg : Llm_provider.Provider_config.t) =
  (tool_policy_for_config provider_cfg).supports_runtime_mcp_http_headers
;;

let apply_override (base : capabilities) (override : runtime_capabilities_override option) : capabilities =
  match override with
  | None -> base
  | Some o ->
    { supports_inline_tools =
        (match o.supports_inline_tools with None -> base.supports_inline_tools | Some v -> v)
    ; supports_inline_tool_choice =
        (match o.supports_inline_tool_choice with
         | None -> base.supports_inline_tool_choice
         | Some v -> v)
    ; supports_runtime_mcp_tools =
        (match o.supports_runtime_mcp_tools with
         | None -> base.supports_runtime_mcp_tools
         | Some v -> v)
    ; supports_runtime_tool_events =
        (match o.supports_runtime_tool_events with
         | None -> base.supports_runtime_tool_events
         | Some v -> v)
    ; supports_runtime_mcp_http_headers =
        (match o.supports_runtime_mcp_http_headers with
         | None -> base.supports_runtime_mcp_http_headers
         | Some v -> v)
    }
;;

let capabilities_of_config ?override (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = oas_capabilities_of_config provider_cfg in
  let (base : capabilities) =
    { supports_inline_tools = caps.supports_tools
    ; supports_inline_tool_choice = caps.supports_tools && caps.supports_tool_choice
    ; supports_runtime_mcp_tools = caps.supports_runtime_mcp_tools
    ; supports_runtime_tool_events = caps.supports_runtime_tool_events
    ; supports_runtime_mcp_http_headers = supports_runtime_mcp_http_headers provider_cfg
    }
  in
  apply_override base override
;;

let provider_supports_inline_tools ?override (provider_cfg : Llm_provider.Provider_config.t) =
  (capabilities_of_config ?override provider_cfg).supports_inline_tools
;;

let provider_supports_runtime_mcp_lane ?override (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = capabilities_of_config ?override provider_cfg in
  caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events
;;

let provider_requires_per_keeper_bridging_for_bound_actor_tools
      (provider_cfg : Llm_provider.Provider_config.t)
  =
  (tool_policy_for_config provider_cfg)
    .requires_per_keeper_bridging_for_bound_actor_tools
;;

let provider_kind_requires_per_keeper_bridging_for_bound_actor_tools kind =
  (tool_policy_for_kind kind).requires_per_keeper_bridging_for_bound_actor_tools
;;

let provider_kind_tolerates_bound_actor_fallback kind =
  (tool_policy_for_kind kind).tolerates_bound_actor_fallback
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
  (* General HTTP-header support OR the declarative identity-header carve-out.
     The identity carve-out covers `x-masc-*` routing labels and other
     non-secret headers declared on the provider capability row.
     [Authorization] is NOT carried here: it is handled separately by
     [provider_supports_bridged_authorization_header] below, which requires
     both provider-level per-keeper bridging and the x-masc-agent-name /
     x-masc-keeper-name identity headers to be present on the same request.
     The carve-out set lives on the declarative provider capability row, not
     in this consumer module. *)
  let tool_policy = tool_policy_for_config provider_cfg in
  if tool_policy.supports_runtime_mcp_http_headers
  then true
  else (
    let wanted = normalize_label key in
    List.exists
      (fun candidate -> String.equal wanted (normalize_label candidate))
      tool_policy.identity_runtime_mcp_header_keys)
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
  && provider_requires_per_keeper_bridging_for_bound_actor_tools provider_cfg
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
      ?override
      ?runtime_mcp_policy
      ~require_tool_choice_support
      ~require_tool_support
      (provider_cfg : Llm_provider.Provider_config.t)
  =
  if (not require_tool_choice_support) && not require_tool_support
  then true
  else (
    let caps = capabilities_of_config ?override provider_cfg in
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
   can show "5 cli_tool_a + 1 cli_tool_c rejected for
   runtime_mcp_http_headers_required" instead of a flat counter.

   Priority order (most-specific first):
   1. [runtime_mcp_http_headers_required] — runtime_mcp caps are
      present but the policy demands HTTP headers and the provider
      does not support them. This is the #10474 case; operator can
      either swap to stdio MCP or pick header-capable providers.
   2. [runtime_mcp_caps_missing] — provider lacks
      [supports_runtime_mcp_tools] or [supports_runtime_tool_events].
      Inline path was also unavailable; runtime authoring problem.
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
      ?override
      ?runtime_mcp_policy
      ~require_tool_choice_support
      ~require_tool_support
      (provider_cfg : Llm_provider.Provider_config.t)
  =
  if (not require_tool_choice_support) && not require_tool_support
  then None
  else if
    supports_required_tool_use
      ?override
      ?runtime_mcp_policy
      ~require_tool_choice_support
      ~require_tool_support
      provider_cfg
  then None
  else (
    let caps = capabilities_of_config ?override provider_cfg in
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
   operators can see which rejection reason dominates per runtime.
   Cardinality: runtimes × provider_kinds × ~5 reasons; bounded by
   the small set of runtime names actually configured (~10) and
   provider kinds (~10). *)
let runtime_filter_rejection_metric = "masc_runtime_filter_rejection_total"

let record_filter_rejection ~runtime ~provider_cfg ~reason =
  Prometheus.inc_counter
    runtime_filter_rejection_metric
    ~labels:
      [ "runtime", runtime
      ; "provider_kind", provider_kind_label provider_cfg
      ; "reason", rejection_reason_label reason
      ]
    ()
;;

let apply_required_tool_use_filter
      ?override
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
           ?override
           ?runtime_mcp_policy
           ~require_tool_choice_support
           ~require_tool_support)
        providers
    in
    (* #10474: emit per-provider rejection observability so dashboards
       can attribute "runtime dead" events to a specific cause. The
       all-providers-removed warn line below kept for human-readable
       logs; counter is the machine-consumable signal. *)
    List.iter
      (fun provider_cfg ->
         match
           classify_rejection
             ?override
             ?runtime_mcp_policy
             ~require_tool_choice_support
             ~require_tool_support
             provider_cfg
         with
         | Some reason -> record_filter_rejection ~runtime:label ~provider_cfg ~reason
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
        "runtime %s: required tool-use gate removed all providers (providers=[%s], \
         runtime_mcp_http_headers=%b)"
        label
        (String.concat ", " (List.map provider_debug_label providers))
        runtime_mcp_http_headers);
    kept)
;;

let apply_required_tool_use_filter_with_overrides
      ?runtime_mcp_policy
      ~require_tool_choice_support
      ~require_tool_support
      ~label
      (providers : (Llm_provider.Provider_config.t * runtime_capabilities_override option) list)
  =
  if (not require_tool_choice_support) && not require_tool_support
  then providers
  else (
    let kept, rejected =
      List.partition
        (fun (provider_cfg, override) ->
           supports_required_tool_use
             ?override
             ?runtime_mcp_policy
             ~require_tool_choice_support
             ~require_tool_support
             provider_cfg)
        providers
    in
    List.iter
      (fun (provider_cfg, override) ->
         match
           classify_rejection
             ?override
             ?runtime_mcp_policy
             ~require_tool_choice_support
             ~require_tool_support
             provider_cfg
         with
         | Some reason -> record_filter_rejection ~runtime:label ~provider_cfg ~reason
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
        "runtime %s: required tool-use gate removed all providers (providers=[%s], \
         runtime_mcp_http_headers=%b)"
        label
        (String.concat ", " (List.map (fun (cfg, _) -> provider_debug_label cfg) providers))
        runtime_mcp_http_headers);
    kept)
;;

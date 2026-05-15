type capabilities =
  { supports_inline_tools : bool
  ; supports_inline_tool_choice : bool
  ; supports_runtime_mcp_tools : bool
  ; supports_runtime_tool_events : bool
  ; supports_runtime_mcp_http_headers : bool
  }

type tool_policy =
  { supports_runtime_mcp_http_headers : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
  ; identity_runtime_mcp_header_keys : string list
  ; tolerates_bound_actor_fallback : bool
  }

module Decl = Cascade_declarative_types
module Parser = Cascade_declarative_parser
module Runtime_binding = Agent_sdk.Provider_runtime_binding

let default_tool_policy =
  { supports_runtime_mcp_http_headers = false
  ; requires_per_keeper_bridging_for_bound_actor_tools = false
  ; identity_runtime_mcp_header_keys = []
  ; tolerates_bound_actor_fallback = false
  }
;;

let normalize_label label = String.trim label |> String.lowercase_ascii

let normalize_provider_id_variant label ~map_char =
  normalize_label label |> String.map map_char
;;

let provider_id_candidates label =
  let raw = normalize_label label in
  [ raw
  ; normalize_provider_id_variant label ~map_char:(fun c ->
      if c = '-' then '_' else c)
  ; normalize_provider_id_variant label ~map_char:(fun c ->
      if c = '_' then '-' else c)
  ]
  |> List.filter (fun value -> not (String.equal value ""))
  |> List.sort_uniq String.compare
;;

let provider_id_candidates_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let from_binding =
    Runtime_binding.binding_for_provider_config provider_cfg
    |> Option.map (fun binding -> binding.Runtime_binding.id)
    |> Option.to_list
  in
  let from_registry =
    [ Llm_provider.Provider_registry.provider_name_of_config provider_cfg ]
  in
  from_binding @ from_registry
  |> List.concat_map provider_id_candidates
  |> List.sort_uniq String.compare
;;

let provider_id_candidates_of_kind kind =
  let provider_cfg =
    Llm_provider.Provider_config.make ~kind ~model_id:"auto" ~base_url:"" ()
  in
  provider_id_candidates_of_config provider_cfg
;;

let rec repo_seed_cascade_path_from dir =
  let candidate =
    Filename.concat (Filename.concat dir "config") Config_dir_resolver.cascade_toml_filename
  in
  if Sys.file_exists candidate
  then Some candidate
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else repo_seed_cascade_path_from parent)
;;

let repo_seed_cascade_path () = repo_seed_cascade_path_from (Sys.getcwd ())

let cascade_policy_path () =
  match Config_dir_resolver.cascade_path_opt () with
  | Some path -> Some path
  | None -> repo_seed_cascade_path ()
;;

type cached_cascade =
  { path : string
  ; mtime : float
  ; parsed : Decl.cascade_config option
  }

let cascade_cache : cached_cascade option ref = ref None

let file_mtime path =
  try Some (Unix.stat path).Unix.st_mtime with
  | Unix.Unix_error _ -> None
;;

let parse_cascade_policy path =
  match Parser.parse_file path with
  | Ok cfg -> Some cfg
  | Error _ -> None
;;

let cascade_policy_config () =
  match cascade_policy_path () with
  | None -> None
  | Some path ->
    (match file_mtime path with
     | None -> None
     | Some mtime ->
       (match !cascade_cache with
        | Some cached
          when String.equal cached.path path && Float.equal cached.mtime mtime ->
          cached.parsed
        | _ ->
          let parsed = parse_cascade_policy path in
          cascade_cache := Some { path; mtime; parsed };
          parsed))
;;

let tool_policy_of_decl_capabilities
      (caps : Decl.cascade_capabilities option)
  =
  match caps with
  | None -> default_tool_policy
  | Some c ->
    { supports_runtime_mcp_http_headers = c.supports_runtime_mcp_http_headers
    ; requires_per_keeper_bridging_for_bound_actor_tools =
        c.requires_per_keeper_bridging_for_bound_actor_tools
    ; identity_runtime_mcp_header_keys = c.identity_runtime_mcp_header_keys
    ; tolerates_bound_actor_fallback = c.tolerates_bound_actor_fallback
    }
;;

let declarative_tool_policy_for_provider_ids provider_ids =
  match cascade_policy_config () with
  | None -> None
  | Some cfg ->
    provider_ids
    |> List.find_map (fun provider_id ->
      match Decl.provider_of_id cfg provider_id with
      | None -> None
      | Some provider ->
        Some (tool_policy_of_decl_capabilities provider.Decl.capabilities))
;;

let binding_supports_runtime_mcp_http_headers (binding : Runtime_binding.t) =
  match binding.Runtime_binding.transport with
  | Runtime_binding.Cli -> binding.Runtime_binding.capabilities.supports_tools
  | Runtime_binding.Http
  | Runtime_binding.Managed
  | Runtime_binding.Custom_openai_compat -> false
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
         | Runtime_binding.Cli -> true
         | Runtime_binding.Http
         | Runtime_binding.Managed
         | Runtime_binding.Custom_openai_compat -> false)
    }
;;

let tool_policy_for_config provider_cfg =
  match declarative_tool_policy_for_provider_ids (provider_id_candidates_of_config provider_cfg) with
  | Some policy -> policy
  | None -> fallback_tool_policy_for_config provider_cfg
;;

let fallback_tool_policy_for_kind kind =
  let provider_cfg =
    Llm_provider.Provider_config.make ~kind ~model_id:"auto" ~base_url:"" ()
  in
  fallback_tool_policy_for_config provider_cfg
;;

let tool_policy_for_kind kind =
  match declarative_tool_policy_for_provider_ids (provider_id_candidates_of_kind kind) with
  | Some policy -> policy
  | None -> fallback_tool_policy_for_kind kind
;;

(** Whether the resolved provider config is a CLI runtime (Claude Code,
    Codex CLI, Gemini CLI, Kimi CLI).  MASC uses this only for local
    tool-delivery projection after OAS has resolved provider/model
    capabilities. *)
let is_cli_agent_provider (provider_cfg : Llm_provider.Provider_config.t) =
  Llm_provider.Provider_config.is_subprocess_cli provider_cfg.kind
;;

(** [normalize_cli_caps_when ~is_cli caps] overrides CLI runtime caps when
    [is_cli] is [true]. Decoupled from [is_cli_agent_provider] so callers
    that have already resolved the provider config (e.g.
    [oas_capabilities_of_config] below) can avoid re-resolving for the same
    provider.

    Override semantics: CLI providers (Claude Code, Codex CLI, Gemini CLI,
    Kimi CLI) do not expose inline function-calling to this gate. Runtime MCP
    support remains cascade.toml/OAS-owned because not every CLI can consume
    request-scoped MCP policy; Gemini CLI is the known false case. *)
let normalize_cli_caps_when ~is_cli (caps : Llm_provider.Capabilities.capabilities) =
  if is_cli
  then { caps with supports_tools = false; supports_tool_choice = false }
  else caps
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
    let tool_policy = tool_policy_for_config provider_cfg in
    let runtime_mcp_lane =
      tool_policy.supports_runtime_mcp_http_headers
      || tool_policy.requires_per_keeper_bridging_for_bound_actor_tools
    in
    { (normalize_cli_caps_when ~is_cli caps) with
      supports_runtime_mcp_tools = runtime_mcp_lane
    ; supports_runtime_tool_events = runtime_mcp_lane
    }
  else caps
;;

let supports_runtime_mcp_http_headers (provider_cfg : Llm_provider.Provider_config.t) =
  (tool_policy_for_config provider_cfg).supports_runtime_mcp_http_headers
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

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

(** Resolve OAS-level capabilities for a provider config.

    Returns OAS's resolved capabilities unchanged in practice. The
    [runtime_mcp_lane] upgrade below is currently unreachable, and the
    operator-level [providers.<id>.capabilities] [supports-runtime-mcp-tools] /
    [supports-runtime-tool-events] declared in config/runtime.toml is parsed
    into [Runtime_schema.provider.capabilities] but read by no runtime
    consumer, so provider-level runtime-MCP intent is dropped today
    (masc#22771).

    The upgrade branch is left in place deliberately — it is the (broken)
    honor path, and deleting it would silently cement the config drop. Whether
    to honor the operator flag (revives the RFC-0206 override) or formally
    deprecate it is the open decision tracked in masc#22771. *)
let oas_capabilities_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let caps =
    Agent_sdk.Provider_runtime_binding.capabilities_for_provider_config provider_cfg
  in
  (* [tool_policy_for_config] is total (binding lookup returns [option]; the
     policy is a pure record build with no I/O), so no exception handler is
     warranted here: a raised [Eio.Cancel.Cancelled] / [Out_of_memory] must
     propagate, not be absorbed into a degraded capability set. *)
  let tool_policy = tool_policy_for_config provider_cfg in
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
  else caps
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

let provider_debug_label (cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf
    "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    cfg.model_id
;;

let provider_kind_label (cfg : Llm_provider.Provider_config.t) =
  Llm_provider.Provider_config.string_of_provider_kind cfg.kind
;;



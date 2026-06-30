(** Provider_tool_support — provider capability negotiation.

    SSOT for "can this provider serve a tool-using turn?" decisions.
    Two layers:
    - {!capabilities}: per-provider boolean record (inline / runtime-MCP).
    - {!provider_supports_runtime_mcp_policy}: policy-level gate.

    Internal helper {!supports_runtime_mcp_http_headers} stays private. *)

(** {1 Capability record} *)

(** Local capability projection consumed by runtime filtering.

    Distinct from {!Llm_provider.Capabilities.capabilities}: this
    record collapses [supports_tools && supports_tool_choice] into a
    single [supports_inline_tool_choice] and adds runtime-MCP HTTP
    headers as a first-class field (queried via runtime.toml provider
    capabilities and OAS runtime bindings). *)
type capabilities =
  { supports_inline_tools : bool
  ; supports_inline_tool_choice : bool
  ; supports_runtime_mcp_tools : bool
  ; supports_runtime_tool_events : bool
  ; supports_runtime_mcp_http_headers : bool
  }

(** Per-provider declarative capability override.
    [None] fields inherit from the OAS runtime binding;
    [Some v] fields replace the runtime-derived value. *)
type runtime_capabilities_override =
  { supports_inline_tools : bool option
  ; supports_inline_tool_choice : bool option
  ; supports_runtime_mcp_tools : bool option
  ; supports_runtime_tool_events : bool option
  ; supports_runtime_mcp_http_headers : bool option
  }

(** {1 Capability resolution} *)

(** [oas_capabilities_of_config cfg] returns OAS-resolved
    {!Llm_provider.Capabilities.capabilities}. Provider/model/catalog
    capability truth comes from OAS [Provider_runtime_binding]; deprecated
    runtime.toml [supports-runtime-mcp-*] provider flags are not honored. *)
val oas_capabilities_of_config
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Capabilities.capabilities

(** [capabilities_of_config cfg] returns the local
    {!capabilities} record.  Composition:

    - [supports_inline_tools = caps.supports_tools]
    - [supports_inline_tool_choice =
       caps.supports_tools && caps.supports_tool_choice]
    - [supports_runtime_mcp_tools] / [supports_runtime_tool_events]:
      OAS passthrough.
    - [supports_runtime_mcp_http_headers]: queried via the local
      binding-derived provider-tool policy projection. *)
val capabilities_of_config
  :  ?override:runtime_capabilities_override
  -> Llm_provider.Provider_config.t
  -> capabilities

(** [provider_supports_inline_tools cfg] is shorthand for
    [(capabilities_of_config cfg).supports_inline_tools]. *)
val provider_supports_inline_tools
  :  ?override:runtime_capabilities_override
  -> Llm_provider.Provider_config.t
  -> bool

(** [provider_supports_runtime_mcp_lane cfg] is true iff both
    [supports_runtime_mcp_tools] and [supports_runtime_tool_events]
    hold.  HTTP-header support is {b not} required at this level —
    that gate is enforced by {!provider_supports_runtime_mcp_policy}. *)
val provider_supports_runtime_mcp_lane
  :  ?override:runtime_capabilities_override
  -> Llm_provider.Provider_config.t
  -> bool

(** [provider_requires_per_keeper_bridging_for_bound_actor_tools cfg] is
    MASC's local runtime-MCP transport policy projection for CLI providers that
    cannot carry arbitrary request-scoped HTTP headers. *)
val provider_requires_per_keeper_bridging_for_bound_actor_tools
  :  Llm_provider.Provider_config.t
  -> bool

(** Kind-only variant for call sites that have not materialized a full
    provider config yet. *)
val provider_kind_requires_per_keeper_bridging_for_bound_actor_tools
  :  Llm_provider.Provider_config.provider_kind
  -> bool

(** Kind-only fallback tolerance used by catalog validation for
    keeper-bound runtime-MCP dispatch. *)
val provider_kind_tolerates_bound_actor_fallback
  :  Llm_provider.Provider_config.provider_kind
  -> bool

(** [runtime_mcp_policy_requires_http_headers policy] is true iff
    [policy.servers] contains at least one
    [Http_server { headers = _ :: _; _ }] entry.  Pure predicate
    used to decide whether the runtime-MCP gate must additionally
    require [supports_runtime_mcp_http_headers]. *)
val runtime_mcp_policy_requires_http_headers
  :  Llm_provider.Llm_transport.runtime_mcp_policy
  -> bool

(** [runtime_mcp_policy_requires_unsupported_http_headers cfg policy]
    is true iff [policy] contains an HTTP header that [cfg] cannot
    carry.  This is stricter than
    {!runtime_mcp_policy_requires_http_headers}: it consults the local
    provider-tool policy's identity-header carve-out.

    Example: [codex_cli] declares
    [supports_runtime_mcp_http_headers = false] (no general header
    support) but carries an identity-header carve-out covering
    [Authorization] (rewritten into [bearer_token_env_var] so the
    secret is delivered via subprocess env, not argv) and the
    non-secret MASC routing labels [x-masc-agent-name] /
    [x-masc-keeper-name].  Any other header key (e.g.
    [x-masc-internal-token] or arbitrary user-supplied headers) is
    still treated as unsupported and rejects the policy. *)
val runtime_mcp_policy_requires_unsupported_http_headers
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Llm_transport.runtime_mcp_policy
  -> bool

(** [provider_supports_runtime_mcp_policy cfg policy] returns true
    iff the provider supports runtime-MCP {b and} the policy's
    provider-specific HTTP-header requirements are satisfied. *)
val provider_supports_runtime_mcp_policy
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Llm_transport.runtime_mcp_policy
  -> bool

(** {1 Provider labels (debug / metric)} *)

(** [provider_debug_label cfg] returns ["<kind>:<model_id>"] for
    human-readable warn lines (runtime-dead diagnostics). *)
val provider_debug_label : Llm_provider.Provider_config.t -> string

(** [provider_kind_label cfg] returns the provider kind alone — used
    as the [provider_kind=] Otel_metric_store counter label. *)
val provider_kind_label : Llm_provider.Provider_config.t -> string

(** {1 Otel_metric_store filter-rejection counter (#10474)} *)


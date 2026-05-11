(** Provider_tool_support — provider capability negotiation +
    cascade rejection classification.

    SSOT for "can this provider serve a tool-using turn?" decisions.
    Three layers:
    - {!capabilities}: per-provider boolean record (inline / runtime-MCP).
    - {!supports_required_tool_use}: yes/no gate.
    - {!classify_rejection} / {!apply_required_tool_use_filter}: #10474
      priority-ordered rejection observability for cascade dashboards.

    Internal helpers ({!normalize_cli_provider_caps},
    {!supports_runtime_mcp_http_headers}) stay private. *)

(** {1 Capability record} *)

type capabilities = {
  supports_inline_tools : bool;
  supports_inline_tool_choice : bool;
  supports_runtime_mcp_tools : bool;
  supports_runtime_tool_events : bool;
  supports_runtime_mcp_http_headers : bool;
}
(** Local capability projection consumed by cascade filtering.

    Distinct from {!Llm_provider.Capabilities.capabilities}: this
    record collapses [supports_tools && supports_tool_choice] into a
    single [supports_inline_tool_choice] and adds runtime-MCP HTTP
    headers as a first-class field (queried via Provider_adapter). *)

(** {1 Capability resolution} *)

val oas_capabilities_of_config :
  Llm_provider.Provider_config.t ->
  Llm_provider.Capabilities.capabilities
(** [oas_capabilities_of_config cfg] returns the OAS-side
    {!Llm_provider.Capabilities.capabilities}.  Resolution order:

    + Per-kind base via
      {!Provider_adapter.oas_capabilities_of_config} (SSOT for the
      [provider_kind → capabilities] mapping).
    + For non-CLI-agent adapters, override with
      {!Llm_provider.Capabilities.for_model_id} when present.
    + CLI-agent normalisation: adapters with
      [runtime_kind = Cli_agent] (Claude Code / Codex CLI / Gemini CLI /
      Kimi CLI) force [supports_tools = false],
      [supports_tool_choice = false], [supports_runtime_mcp_tools = true],
      and [supports_runtime_tool_events = true].
    + [provider_cfg.supports_tool_choice_override] (if [Some _])
      overrides the resolved [supports_tool_choice]. *)

val capabilities_of_config :
  Llm_provider.Provider_config.t -> capabilities
(** [capabilities_of_config cfg] returns the local
    {!capabilities} record.  Composition:

    - [supports_inline_tools = caps.supports_tools]
    - [supports_inline_tool_choice =
       caps.supports_tools && caps.supports_tool_choice]
    - [supports_runtime_mcp_tools] / [supports_runtime_tool_events]:
      passthrough.
    - [supports_runtime_mcp_http_headers]: queried via
      [Provider_adapter.supports_runtime_mcp_http_headers_for_config]. *)

val provider_supports_inline_tools :
  Llm_provider.Provider_config.t -> bool
(** [provider_supports_inline_tools cfg] is shorthand for
    [(capabilities_of_config cfg).supports_inline_tools]. *)

val provider_supports_runtime_mcp_lane :
  Llm_provider.Provider_config.t -> bool
(** [provider_supports_runtime_mcp_lane cfg] is true iff both
    [supports_runtime_mcp_tools] and [supports_runtime_tool_events]
    hold.  HTTP-header support is {b not} required at this level —
    that gate is enforced by {!provider_supports_runtime_mcp_policy}. *)

val runtime_mcp_policy_requires_http_headers :
  Llm_provider.Llm_transport.runtime_mcp_policy -> bool
(** [runtime_mcp_policy_requires_http_headers policy] is true iff
    [policy.servers] contains at least one
    [Http_server { headers = _ :: _; _ }] entry.  Pure predicate
    used to decide whether the runtime-MCP gate must additionally
    require [supports_runtime_mcp_http_headers]. *)

val runtime_mcp_policy_requires_unsupported_http_headers :
  Llm_provider.Provider_config.t ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  bool
(** [runtime_mcp_policy_requires_unsupported_http_headers cfg policy]
    is true iff [policy] contains an HTTP header that [cfg] cannot
    carry.  This is stricter than
    {!runtime_mcp_policy_requires_http_headers}: [codex_cli] may carry
    the non-secret MASC identity headers
    [x-masc-agent-name] and [x-masc-keeper-name], but still rejects
    auth-bearing headers such as [Authorization] and
    [x-masc-internal-token]. *)

val provider_supports_runtime_mcp_policy :
  Llm_provider.Provider_config.t ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  bool
(** [provider_supports_runtime_mcp_policy cfg policy] returns true
    iff the provider supports runtime-MCP {b and} the policy's
    provider-specific HTTP-header requirements are satisfied. *)

val supports_required_tool_use :
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  Llm_provider.Provider_config.t ->
  bool
(** [supports_required_tool_use ?runtime_mcp_policy
      ~require_tool_choice_support ~require_tool_support cfg]
    returns the cascade filter gate.  Truth table:

    {ul
    {- [(false, false)] -> [true] (filter disabled).}
    {- [(true, true)] -> [supports_inline_tool_choice || runtime_mcp].}
    {- [(true, false)] -> [supports_inline_tool_choice].}
    {- [(false, true)] -> [supports_inline_tools || runtime_mcp].}}

    [runtime_mcp] resolves through {!provider_supports_runtime_mcp_policy}
    when [runtime_mcp_policy = Some _], else through the lane gate. *)

(** {1 Rejection classification (#10474)} *)

(** Closed variant — priority-ordered rejection causes for dashboards.
    Order is most-specific / most-actionable first; see
    {!classify_rejection}. *)
type rejection_reason =
  | Runtime_mcp_http_headers_required
      (** Runtime-MCP caps are present but the policy demands HTTP
          headers and the provider does not support them.  Operator
          remedy: swap to stdio MCP {b or} pick a header-capable
          provider. *)
  | Runtime_mcp_caps_missing
      (** Provider lacks [supports_runtime_mcp_tools] or
          [supports_runtime_tool_events].  Inline path was also
          unavailable; cascade authoring problem. *)
  | Inline_tool_choice_unsupported
      (** Only [require_tool_choice] mode and provider has no
          [supports_inline_tool_choice]. *)
  | Inline_tools_unsupported
      (** Only [require_tool_support] mode and provider has no
          [supports_inline_tools]. *)
  | Filter_disabled
      (** Both [require_*] flags false — defensive default that
          should never be emitted in practice. *)

val rejection_reason_label : rejection_reason -> string
(** [rejection_reason_label r] returns the canonical snake_case label
    used as the [reason=] Prometheus counter label.  Pinned literals:
    [runtime_mcp_http_headers_required] / [runtime_mcp_caps_missing] /
    [inline_tool_choice_unsupported] / [inline_tools_unsupported] /
    [filter_disabled]. *)

val classify_rejection :
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  Llm_provider.Provider_config.t ->
  rejection_reason option
(** [classify_rejection ... cfg] returns [None] if the provider
    passes the filter, otherwise [Some r] where [r] is the
    most-specific rejection cause per the priority table above.

    Returns [None] when both [require_*] flags are false (filter
    disabled — no rejection to classify). *)

(** {1 Provider labels (debug / metric)} *)

val provider_debug_label : Llm_provider.Provider_config.t -> string
(** [provider_debug_label cfg] returns ["<kind>:<model_id>"] for
    human-readable warn lines (cascade-dead diagnostics). *)

val provider_kind_label : Llm_provider.Provider_config.t -> string
(** [provider_kind_label cfg] returns the provider kind alone — used
    as the [provider_kind=] Prometheus counter label. *)

(** {1 Prometheus filter-rejection counter (#10474)} *)

val cascade_filter_rejection_metric : string
(** Pinned literal: ["masc_cascade_filter_rejection_total"].

    Cardinality bound: cascades (~10) × provider_kinds (~10) ×
    reasons (5) ≈ 500 series ceiling. *)

val record_filter_rejection :
  cascade:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  reason:rejection_reason ->
  unit
(** [record_filter_rejection ~cascade ~provider_cfg ~reason]
    increments {!cascade_filter_rejection_metric} with labels
    [(cascade, provider_kind, reason)].  Counter is the
    machine-consumable signal for cascade-dead dashboards. *)

(** {1 Filter application} *)

val apply_required_tool_use_filter :
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  label:string ->
  Llm_provider.Provider_config.t list ->
  Llm_provider.Provider_config.t list
(** [apply_required_tool_use_filter ... ~label providers] partitions
    [providers] using {!supports_required_tool_use}, emits one
    {!record_filter_rejection} call per rejected provider, and warns
    via {!Log.Misc.warn} when {b every} provider was filtered out.

    The cascade-dead warn line embeds [label],
    [provider_debug_label] for each input provider, and
    [runtime_mcp_http_headers] (the policy's HTTP-header demand
    flag).  Returns the kept providers in input order. *)

(** Oas_worker_named_cascade — Eio context, cascade resolution, runtime MCP policy.

    Extracted from oas_worker_named.ml (God file decomposition).
    Provides cascade profile defaults, Eio context validation,
    provider resolution, tool-support filtering, and cross-cascade fallback.

    This module is [include]d by {!Oas_worker_named}; all bindings are
    re-exported by the facade.  @since God file decomposition *)

(** {1 Cascade profile defaults} *)

val default_config_path : unit -> string option
(** Alias for [Cascade_runtime.cascade_config_path]. *)

val default_model_strings : cascade_name:string -> string list
(** Alias for [Cascade_runtime.default_model_strings]. *)

(** {1 Eio context validation} *)

val require_eio :
  ?sw:Eio.Switch.t -> ?net:Eio_context.eio_net -> unit ->
  (Eio.Switch.t * Eio_context.eio_net, string) result
(** Validate that an Eio switch and network are available in the current
    context.  Returns [Ok (sw, net)] when both are present, or [Error msg]
    when running outside a server context. *)

val eio_context_error_to_sdk_error : string -> Agent_sdk.Error.sdk_error
(** Lift a context-missing diagnostic string into an [Agent_sdk.Error.Config]
    error with field ["eio_context"]. *)

val cascade_catalog_error_to_sdk_error : string -> Agent_sdk.Error.sdk_error
(** Lift a cascade-catalog diagnostic into an [Agent_sdk.Error.Config]
    error with field ["cascade_name"]. *)

(** {1 Provider resolution} *)

val resolve_cascade_providers :
  ?provider_filter:string list ->
  ?require_tool_choice_support:bool ->
  ?require_tool_support:bool ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  cascade_name:Keeper_cascade_profile.runtime_name -> unit ->
  (Llm_provider.Provider_config.t list, string) result
(** Resolve cascade provider configs via MASC Cascade_config. *)

val resolve_providers_from_model_strings :
  ?provider_filter:string list ->
  ?require_tool_choice_support:bool ->
  ?require_tool_support:bool ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  string list ->
  Llm_provider.Provider_config.t list
(** Resolve from an explicit model string list (user-declared in keeper TOML). *)

val keeper_agent_name_opt : string -> string option
(** Derive the agent name from a keeper name; [None] when the name is empty. *)

val runtime_mcp_policy_for_tools :
  keeper_name:string -> Agent_sdk.Tool.t list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
(** Build a runtime MCP policy from the tool list, honouring public MCP tools
    and keeper-internal surface classifications. *)

val keeper_internal_tool_names_for_runtime_surface :
  keeper_name:string -> Agent_sdk.Tool.t list -> string list
(** Keeper-internal tool names that require a keeper-bound runtime surface for
    the given keeper. Empty when [keeper_name] is blank. *)

val keeper_internal_tools_require_materialized_runtime_surface :
  keeper_name:string -> Agent_sdk.Tool.t list -> bool
(** [true] when the active tool surface contains keeper-internal tools that
    must not be silently dropped by an optional CLI/runtime-MCP lane. *)

val runtime_mcp_policy_for_provider :
  keeper_name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
(** Normalise a runtime MCP policy for a specific provider, injecting the
    keeper's agent name when applicable. *)

val codex_cli_cannot_carry_keeper_bound_runtime_mcp :
  keeper_name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  bool
(** [true] when the provider is codex_cli and the policy includes tools that
    require a bound-actor (keeper-scoped) runtime MCP — codex_cli cannot
    carry these across its CLI subprocess boundary. *)

(** {1 Provider filter rejection classification} *)

type filter_rejection_reason =
  | Codex_keeper_bound_actor_required
  | Tool_lane_unsupported
  | Required_tool_use of Provider_tool_support.rejection_reason
(** Why a provider was rejected by the cascade filter.  Order mirrors the
    filter's short-circuit priority. *)

val filter_rejection_reason_label : filter_rejection_reason -> string

val classify_filter_rejection :
  keeper_name:string ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  ?tools:Agent_sdk.Tool.t list ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  Llm_provider.Provider_config.t ->
  filter_rejection_reason option
(** Classify why a single provider would be rejected by the tool-use gate. *)

val filter_candidate_providers_for_tool_support :
  keeper_name:string ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  ?tools:Agent_sdk.Tool.t list ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  ?secondary_resolver:
    (int ->
     Llm_provider.Provider_config.t ->
     Llm_provider.Provider_config.t option) ->
  label:string ->
  Llm_provider.Provider_config.t list ->
  Llm_provider.Provider_config.t list
(** Filter provider candidates through the tool-use gate.  When the gate
    empties the list, emits a deduplicated diagnostic (ERROR on first
    occurrence per signature, DEBUG on repeats).

    @param secondary_resolver RFC-0027 PR-9b dual-track callback. When
    set, each rejected primary is offered to the resolver; if it returns
    a [Some secondary] candidate that itself passes the tool-use gate,
    the secondary replaces the primary in the kept list. The function
    is invoked at most once per rejected primary, with the primary's
    zero-based position in the original candidate list, after the initial
    classification, so it does not affect the hot path when no entries
    have a [secondary] declaration. *)

(** {1 Cross-cascade fallback} *)

val resolve_tool_capable_provider_across_cascades :
  sw:Eio.Switch.t ->
  net:Eio_context.eio_net ->
  keeper_name:string ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  ?tools:Agent_sdk.Tool.t list ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  exclude_cascade:string ->
  unit ->
  (string * Llm_provider.Provider_config.t) option
(** Search all other cascades for a healthy tool-capable provider when the
    current cascade has none after filtering.  Returns the source cascade
    name and provider config, or [None].  Depth: 1 level only. *)

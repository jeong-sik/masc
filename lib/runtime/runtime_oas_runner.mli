(** Runtime_oas_runner — Eio context validation and runtime MCP policy.

    Extracted from oas_worker_named.ml (God file decomposition).
    Provides execution-model defaults, Eio context validation, and
    runtime-MCP policy derivation.

    RFC-0206: the multi-candidate provider filter / dual-track swap machinery
    (and its [Cascade_*] dependencies) is annihilated — a single Runtime has
    no candidate list to filter. Model resolution delegates to
    {!Runtime_model_labels}.

    This module is [include]d by {!Keeper_turn_driver}; all bindings are
    re-exported by the facade.  @since God file decomposition *)

(** {1 Execution-model defaults} *)

val default_config_path : unit -> string option
(** Alias for [Runtime.config_path]. *)

val default_model_strings : unit -> string list
(** Alias for {!Runtime_model_labels.default_model_strings} (default-always;
    no cascade_name). *)

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
(** Lift a runtime-resolution diagnostic into an [Agent_sdk.Error.Config]
    error with field ["cascade_name"]. *)

(** {1 Runtime MCP policy} *)

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

val cli_tool_a_cannot_carry_keeper_bound_runtime_mcp :
  keeper_name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  bool
(** [true] when the provider is cli_tool_a and the policy includes tools that
    require a bound-actor (keeper-scoped) runtime MCP — cli_tool_a cannot
    carry these across its CLI subprocess boundary. *)

(** Runtime_oas_runner — Eio context, runtime resolution, runtime MCP policy.

    Extracted from oas_worker_named.ml (God file decomposition).
    Provides runtime profile defaults, Eio context validation,
    provider resolution, and tool-support filtering.

    This module is [include]d by {!Keeper_turn_driver}; all bindings are
    re-exported by the facade.  @since God file decomposition *)

(** {1 Runtime profile defaults} *)

val default_config_path : unit -> string option
(** Alias for [Runtime.config_path]. *)

val default_model_strings : runtime_id:string -> string list
(** Alias for [Runtime_runtime.default_model_strings]. *)

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

val runtime_catalog_error_to_sdk_error : string -> Agent_sdk.Error.sdk_error
(** Lift a runtime-catalog diagnostic into an [Agent_sdk.Error.Config]
    error with field ["runtime_id"]. *)

(** {1 Provider resolution} *)

val resolve_runtime_providers :
  ?provider_filter:string list ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  runtime_id:string -> unit ->
  (Llm_provider.Provider_config.t list, string) result
(** Resolve runtime provider configs via MASC Runtime_config. *)

(** {1 Keeper name translation (injected)} *)

type keeper_name_xlat =
  { keeper_agent_name : string -> string
  ; keeper_name_from_agent_name : string -> string option
  }
(** The two pure keeper-name translators the runtime needs. Injected by the
    keeper composition root so the runtime does not code-depend on the
    keeper-domain [Keeper_identity] module. *)

val set_keeper_name_xlat : keeper_name_xlat -> unit
(** Register the keeper name translators. Called once by the keeper at init,
    before any runtime tool dispatch. Reading the translators before this is
    called raises (no silent default). *)

val keeper_agent_name_opt : string -> string option
(** Derive the agent name from a keeper name; [None] when the name is empty.
    Requires {!set_keeper_name_xlat} to have run. *)

val runtime_mcp_policy_for_tools :
  keeper_name:string -> Agent_sdk.Tool.t list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
(** Build a runtime MCP policy from the tool list, honouring public MCP tools
    and agent-internal surface classifications. *)

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

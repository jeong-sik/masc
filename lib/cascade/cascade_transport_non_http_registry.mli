(** Non-HTTP cascade transport registry and dispatcher. *)

type non_http_transport_ctor =
  provider_cfg:Llm_provider.Provider_config.t ->
  runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option ->
  cli_transport_overrides:
    Cascade_transport_cli_overrides.cli_transport_overrides option ->
  (Llm_provider.Llm_transport.t, Agent_sdk.Error.sdk_error) result

val register_non_http_transport :
  kind:Llm_provider.Provider_config.provider_kind ->
  ctor:non_http_transport_ctor ->
  unit
(** Register a constructor for a non-HTTP provider kind. *)

val non_http_transport_of_provider :
  sw:Eio.Switch.t ->
  provider_cfg:Llm_provider.Provider_config.t ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  ?cli_transport_overrides:
    Cascade_transport_cli_overrides.cli_transport_overrides ->
  unit ->
  (Llm_provider.Llm_transport.t option, Agent_sdk.Error.sdk_error) result
(** Resolve a provider config to a registered non-HTTP transport when one
    exists; subprocess CLI kinds fail fast when no constructor is registered. *)

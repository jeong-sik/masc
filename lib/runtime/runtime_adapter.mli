(** Single-binding → hot-path [Provider_config.t] materialization (RFC-0206 §5).

    Re-homed from the deleted [Runtime_declarative_adapter], keeping only the
    binding materialization path. Routing layers — aliases, routes,
    system_targets, capability profiles, [Runtime_strategy] mapping, the
    [adapted_catalog] aggregate, and the typed [adapter_error] list — are
    intentionally dropped (a Runtime is one pre-selected binding, not a
    routed catalog). Types are owned by {!Runtime_schema}.

    @stability Internal *)

val binding_to_provider_config
  :  Runtime_schema.config
  -> Runtime_schema.binding
  -> (Llm_provider.Provider_config.t, string) result
(** Materialize one binding into the hot-path {!Llm_provider.Provider_config.t}.

    Resolution chain (no routing):
    - [binding.provider_id] -> {!Runtime_schema.provider_of_id}
    - [binding.model_id] -> {!Runtime_schema.model_of_id}
    - provider transport + model spec -> {!Llm_provider.Provider_config.make}

    Returns [Error reason] (no silent fallback) when the provider or model id
    is unresolved, or when the provider transport/kind cannot be mapped to a
    concrete provider config. *)

(** Single-binding → hot-path [Provider_config.t] materialization (RFC-0206 §5).

    Re-homed from the deleted [Runtime_declarative_adapter], keeping only the
    binding materialization path. Routing layers — aliases, routes,
    system_targets, capability profiles, [Runtime_strategy] mapping, the
    [adapted_catalog] aggregate, and the typed [adapter_error] list — are
    intentionally dropped (a Runtime is one pre-selected binding, not a
    routed catalog). Types are owned by {!Runtime_schema}.

    @stability Internal *)

(** Header keys that carry a credential. Stripped from
    [Provider_config.headers] so a declared auth header is not duplicated
    next to [api_key], and hidden from the dashboard's provider header list.
    Matching is case-insensitive on the trimmed key. *)
val is_auth_header_key : string -> bool

val effective_credential_reference :
  provider_id:string ->
  Runtime_schema.credential option ->
  Runtime_schema.credential option
(** Return the explicit credential reference, or the provider registry's
    declared default environment reference when the runtime row omits one.
    Environment aliases follow the same candidate selection as API-key
    materialization, so the returned non-secret reference names the credential
    that was actually selected. File and inline references are preserved.
    An unregistered provider with no explicit credential remains [None]. *)

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

val binding_to_execution
  :  Runtime_schema.config
  -> Runtime_schema.binding
  -> (Runtime_execution.t, string) result
(** Materialize the owner of a complete turn. HTTP model APIs become
    {!Runtime_execution.Agent_core}. The exact [codex-app-server] protocol over
    a credential-free CLI transport becomes
    {!Runtime_execution.Codex_app_server}; [claude-code] becomes
    {!Runtime_execution.Claude_code}; and [antigravity-cli] becomes
    {!Runtime_execution.Antigravity_cli}. Other CLI protocols remain rejected. *)

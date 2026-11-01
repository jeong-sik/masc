val normalize_http_request_path :
  kind:Llm_provider.Provider_config.provider_kind -> base_url:string -> request_path:string -> string
val default_http_request_path :
  kind:Llm_provider.Provider_config.provider_kind -> base_url:string -> string
(** The uncatalogued HTTP surface, normalized against the endpoint. *)

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
val http_protocol_metadata : Runtime_schema.provider ->
  ((Llm_provider.Provider_config.provider_kind * string), string) result
(** Resolve the actual HTTP kind and request path without a model or credential. *)

(** Capture a fresh named-provider selection from one current registry entry. *)
val materialize_credentials : provider_id:string -> credential:Runtime_schema.credential option ->
  (Runtime_credential_selection.materialized, string) result
(** Missing Env/Inline values and unknown provider requirements remain explicit
    observations. Fresh discovery applies [Runtime_credential_selection.require_key]
    to refuse them; runtime missing-auth projection may retain them. References
    and values are selected together. Errors never contain credential contents. *)

type provider_materialization = private
  { provider_config : Llm_provider.Provider_config.t
  ; credential_admission : Runtime_credential_selection.admission
  }

type execution_materialization = private
  { execution : Runtime_execution.t
  ; credential_admission : Runtime_credential_selection.admission option
  }
(** HTTP executions always carry [Some] selected admission. [None] belongs
    only to official clients, which own their credentials separately. *)

val materialize_provider_binding
  :  Runtime_schema.config
  -> Runtime_schema.binding
  -> (provider_materialization, string) result
(** Materialize one binding into the hot-path {!Llm_provider.Provider_config.t}.

    Catalog-derived model policy, pricing authority and their absence are
    captured at this selection boundary. A later catalog replacement affects
    newly materialized bindings; existing configs retain their selected facts.

    HTTP file credentials contain one raw API key at an absolute path. The
    process-owned regular file is read at materialization; whitespace is
    trimmed. Missing, unreadable, empty, relative, and JSON document references
    return a safe error without including their path or contents.

    Resolution chain (no routing):
    - [binding.provider_id] -> {!Runtime_schema.provider_of_id}
    - [binding.model_id] -> {!Runtime_schema.model_of_id}
    - provider transport + model spec -> {!Llm_provider.Provider_config.make}

    Context declarations resolve binding > provider > model; a genuine catalog
    context ceiling still clamps the result. Synthetic custom-model capabilities
    carry the selected window rather than treating the model default as a cap.

    An explicitly declared model output-token ceiling overrides the catalog
    or provider-base ceiling. An absent declaration preserves the catalog;
    neither ceiling becomes a request-side [max_tokens] default.

    The binding's [disable_parallel_tool_use] is request policy. It reaches
    [Provider_config] without replacing the model's catalog capability.
    The canonical provider must declare suppression support in its catalog;
    HTTP wire compatibility alone is not a support contract.
    Native Ollama and Gemini cannot carry it and refuse [true].

    Returns [Error reason] (no silent fallback) when the provider or model id
    is unresolved, or when the provider transport/kind cannot be mapped to a
    concrete provider config. *)

val materialize_execution
  :  Runtime_schema.config
  -> Runtime_schema.binding
  -> (execution_materialization, string) result
(** Materialize the owner of a complete turn. HTTP model APIs become
    {!Runtime_execution.Agent_core}. The exact [codex-app-server] protocol over
    a credential-free CLI transport becomes
    {!Runtime_execution.Codex_app_server}; [claude-code] becomes
    {!Runtime_execution.Claude_code}; [antigravity-cli] becomes
    {!Runtime_execution.Antigravity_cli}; and [muse-serve] becomes
    {!Runtime_execution.Muse_serve}. These clients have no supported
    [disable_parallel_tool_use] control here, so bindings requesting it are
    refused. Other CLI protocols remain rejected.

    Official-client credentials retain their adapter-specific interpretation.
    The command is spawned from where {!Runtime_official_cli_install.locate}
    finds it at this call: PATH first, then the vendor installer's directory
    for the client's own name. A command found nowhere is kept as configured;
    its absence surfaces when the client is spawned, not here. *)

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

(** Uses the dispatch credential alias/registry resolution. A missing required
    credential is an error; anonymous access is allowed only without an
    effective credential reference. *)
val resolve_api_key : provider_id:string -> credential:Runtime_schema.credential option ->
  (Llm_provider.Secret.t, string) result
(** Resolve the same protected API-key references used by HTTP bindings, for
    model discovery before a model has been selected. Errors never contain the
    credential's contents. This does not authenticate or verify account access.

    A provider with no reference and no catalog row is an error rather than an
    empty secret: nothing has said a key is unnecessary, so answering with one
    would report success without a credential. A catalog row that declares an
    empty [api_key_env] still resolves to the empty secret, which is what a
    keyless provider is. *)

type credential_requirement =
  | Reference of Runtime_schema.credential
      (** A credential to materialize: the runtime row's own, or the catalog's
          declared default environment reference. *)
  | Not_required
      (** The catalog row declares an empty [api_key_env], which is how a
          provider says it takes no key. *)
  | Unknown_provider
      (** The runtime row names no credential and the catalog has no row for
          this provider, so nothing says whether a key is needed. *)

val credential_requirement :
  provider_id:string ->
  Runtime_schema.credential option ->
  credential_requirement
(** Whether this provider needs a credential, and which one names it.

    [Not_required] and [Unknown_provider] are both "no reference", and reading
    them as one answer is what let a missing credential pass as anonymous
    access (#35651). Callers that can proceed without a key should say which of
    the two they are accepting. *)

val effective_credential_reference :
  provider_id:string ->
  Runtime_schema.credential option ->
  Runtime_schema.credential option
(** The reference view of {!credential_requirement}, for callers that ask which
    credential names an identity rather than whether one is needed.

    Environment aliases follow the same candidate selection as API-key
    materialization, so the returned non-secret reference names the credential
    that was actually selected. File and inline references are preserved. Both
    absences answer [None], because neither names a credential. *)

val binding_to_provider_config
  :  Runtime_schema.config
  -> Runtime_schema.binding
  -> (Llm_provider.Provider_config.t, string) result
(** Materialize one binding into the hot-path {!Llm_provider.Provider_config.t}.

    HTTP file credentials contain one raw API key at an absolute path. The
    process-owned regular file is read at materialization; whitespace is
    trimmed. Missing, unreadable, empty, relative, and JSON document references
    return a safe error without including their path or contents. CLI-owned
    credentials retain their adapter-specific interpretation.

    Resolution chain (no routing):
    - [binding.provider_id] -> {!Runtime_schema.provider_of_id}
    - [binding.model_id] -> {!Runtime_schema.model_of_id}
    - provider transport + model spec -> {!Llm_provider.Provider_config.make}

    An explicitly declared model output-token ceiling overrides the catalog
    or provider-base ceiling. An absent declaration preserves the catalog;
    neither ceiling becomes a request-side [max_tokens] default.

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

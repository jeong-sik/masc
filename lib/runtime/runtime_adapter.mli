val normalize_http_request_path :
  kind:Llm_provider.Provider_config.provider_kind -> base_url:string -> request_path:string -> string
val default_http_request_path :
  kind:Llm_provider.Provider_config.provider_kind -> base_url:string -> string
(** The uncatalogued HTTP surface, normalized against the endpoint. *)

(** Single-binding → hot-path [Provider_config.t] materialization.

    Covers only the binding materialization path. Routing layers — aliases, routes,
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

val http_model_declares_tools : Runtime_schema.provider -> Runtime_schema.model_spec -> (bool, string) result
(** Whether [spec] on HTTP [provider] resolves [supports_tools = true] through
    the AGENT_CORE catalog and TOML capabilities without reading credentials. *)

(** Capture a fresh named-provider selection from admitted current declarations. *)
val materialize_credentials : provider_id:string -> credential:Runtime_schema.credential option ->
  (Runtime_credential_selection.materialized, string) result
(** Missing Env/Inline values and unknown provider requirements remain explicit
    observations. Fresh discovery applies [Runtime_credential_selection.require_key]
    to refuse them; runtime missing-auth projection may retain them. References
    and values are selected together. Errors never contain credential contents. *)

type construction
val create_construction : unit -> construction
(** One construction lifetime for a single binding or a complete batch.
    Its first HTTP binding captures admitted declarations before credential
    I/O; all subsequent HTTP bindings share that immutable selection, including
    missing policy. Creating an owner reads no catalog. [Runtime_instance]
    filters native-only, empty, disabled and unresolved cases before unused
    HTTP declarations would be forced; direct adapter callers own validation.
    Create another owner when selecting from newly published catalogs. *)

(** Why a provider's [catalog-provider] is refused. *)
type catalog_provider_refusal =
  | Names_no_row  (** It names no AGENT_CORE catalog provider row. *)
  | Beside_own_row
      (** The provider's own id is a catalog provider row; one provider speaks
          as one row. *)
  | Names_alias of string
      (** It names an alias or another spelling of the row with this id. The
          catalog lookup accepts it, but an exact-output target matches the
          row id as written, so the slot would be left out. *)
  | Beside_kind
      (** The provider states [kind] too, which the catalog row answers. *)

val catalog_provider_refusal_text :
  provider_id:string -> catalog_provider:string -> catalog_provider_refusal -> string

val check_catalog_row
  :  construction:construction
  -> Runtime_schema.provider
  -> (unit, string * catalog_provider_refusal) result
(** Whether the catalog can answer for the row this provider speaks as, read
    from the same declarations [construction] materializes the binding from,
    and the way every catalog lookup in this module reads it. [Error] carries
    the [catalog-provider] the provider wrote. A provider with no
    [catalog-provider] always passes: its id is the row or it has none. *)

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
  :  construction:construction
  -> Runtime_schema.config
  -> Runtime_schema.binding
  -> (provider_materialization, string) result
(** Materialize one binding into the hot-path {!Llm_provider.Provider_config.t}.

    Catalog-derived model policy, pricing authority and their absence are
    captured from the construction owner's immutable admitted selection before
    credential I/O. Catalog replacement affects another construction owner;
    it does not change later bindings using this owner.

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

    Document input is frozen from [supports-document-input] for catalogued and
    uncatalogued models alike. An absent declaration withholds it; a native
    wire without document representation (Ollama) cannot enable it. The same
    frozen capability reaches admission and request serialization.

    The binding's [disable_parallel_tool_use] is request policy. It reaches
    [Provider_config] without replacing the model's catalog capability.
    The canonical provider must declare suppression support in its catalog;
    HTTP wire compatibility alone is not a support contract.
    Native Ollama and Gemini cannot carry it and refuse [true].

    The binding's [cache_retention] is request policy too. A Messages runtime
    whose catalog provider row declares [supports_extended_cache_ttl] carries
    it as [Provider_config.cache_extended_ttl]; every other runtime refuses a
    declared value.

    Returns [Error reason] (no silent fallback) when the provider or model id
    is unresolved, or when the provider transport/kind cannot be mapped to a
    concrete provider config. *)

val materialize_execution
  :  construction:construction
  -> Runtime_schema.config
  -> Runtime_schema.binding
  -> (execution_materialization, string) result
(** Materialize the owner of a complete turn. HTTP model APIs become
    {!Runtime_execution.Agent_core}. The exact [codex-app-server] protocol over
    a credential-free CLI transport becomes
    {!Runtime_execution.Codex_app_server}; [claude-code] becomes
    {!Runtime_execution.Claude_code}; [antigravity-cli] becomes
    {!Runtime_execution.Antigravity_cli}; [muse-serve] becomes
    {!Runtime_execution.Muse_serve}; and [vibe-cli] becomes
    {!Runtime_execution.Vibe_cli}. These clients have no supported
    [disable_parallel_tool_use] or [cache_retention] control here, so bindings
    declaring either are refused. Other CLI protocols remain rejected.

    Official-client credentials retain their adapter-specific interpretation.
    The command is spawned from where {!Runtime_official_cli_install.locate}
    finds it at this call: PATH first, then the vendor installer's directory
    for the client's own name. A command found nowhere is kept as configured;
    its absence surfaces when the client is spawned, not here. A [vibe-cli]
    command is kept exactly as configured, and its binding is refused when it
    declares [reasoning-effort] or [turn-timeout-s]. *)

val materialize_person_execution
  :  construction:construction
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> integration_id:Authz_types.Integration_id.t
  -> account_home:string option
  -> Runtime_schema.config
  -> Runtime_schema.binding
  -> (execution_materialization, string) result
(** Materialize an execution for a person's account using the explicit
    [~account_home] (never the provider declaration's [account_home]), without
    reading key files, home configuration, or process environment at build time.
    - Official clients ([Claude_code], [Codex_app_server], [Muse_serve]) require
      [Some home]; [Claude_code] and [Codex_app_server] hold credential-free
      person seals ({!Runtime_account_access.seal_person}), and [Muse_serve]
      declares its home via {!Runtime_account_access.declare_muse_home}.
    - HTTP [Agent_core] providers ([Messages_api], [Chat_completions_api],
      [Ollama_api], [Gemini_api]) require [account_home = None], drop any
      custom headers, and carry a credential-free person API seal
      ({!Runtime_account_access.seal_person_api}).
    - Providers declaring [credentials], [Vertex_gemini_api], [Antigravity_cli],
      and [Vibe_cli] are refused. *)

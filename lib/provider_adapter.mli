(** Provider_adapter — provider registry, auth resolution, and cascade label
    construction.

    MASC owns local runtime policy and cascade labels. Voice runtime
    policy lives in [Voice_runtime_overlay].
    OAS owns provider identity and transport defaults through
    [Agent_sdk.Provider_runtime_binding]. Adding a new plain provider
    should normally happen in OAS; MASC only needs an explicit adapter
    entry for local policy overrides.

    @since v2.100.0 *)

(** {1 Types} *)

type runtime_kind =
  | Local
  | Cli_agent
  | Direct_api
[@@deriving tla]

type auth_mode =
  | No_auth
  | Cli_cached_login
  | Api_key of string
  | Vertex_adc of
      { project_env : string
      ; location_env : string
      }

type model_family =
  | Generic
  | Glm_general
  | Glm_coding
  | Kimi_api_family

type auto_models_source =
  | No_auto_models
  | Env_csv_or_default of
      { env_var : string
      ; defaults : string list
      ; prefer_default_model_env : bool
      }
  | Zai_general_auto_models
  | Zai_coding_auto_models

type reporting_policy =
  | Reported
  | Missing_by_design
  | Unknown

type model_policy =
  { default_model_env : string option
  ; default_model_fallback : string option
  ; auto_models : auto_models_source
  ; expand_auto : bool
  ; family : model_family
  }

type tool_policy =
  { supports_runtime_mcp_http_headers : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
    (** When true, this provider's runtime cannot inject per-keeper auth
          headers natively. Bound-actor runtime MCP tools therefore require
          explicit per-keeper bridging at the cascade layer; otherwise the
          filter must reject the policy for this provider.

          This is a capability flag. Callers must not dispatch on a vendor or
          provider name to decide whether the bridge is needed. *)
  ; identity_runtime_mcp_header_keys : string list
    (** Header keys the provider can carry even when
          [supports_runtime_mcp_http_headers = false].  Empty for most
          providers. Adapters that require per-keeper bridging may still carry
          selected non-secret MASC identity headers such as
          [x-masc-agent-name] and [x-masc-keeper-name].
          Keys are matched case-insensitively after trimming. *)
  ; argv_prompt_preflight : bool
    (** When true, callers must run a prompt argv/context-window preflight
          before spawning a turn (the runtime serialises the full prompt on
          a single argv vector and rejects oversize input).
          RFC-0058 §2.4: capability flag, not a vendor match. *)
  ; uses_anthropic_caching : bool
    (** When true, the provider's wire format supports Anthropic-style
          prompt caching via [cache_control] blocks, so usage telemetry
          should report [cache_creation_input_tokens] /
          [cache_read_input_tokens] above the cacheable input threshold.
          Used by [Keeper_usage_trust] to flag caching-likely-disabled
          anomalies. RFC-0058 §2.4: capability flag, not a vendor match. *)
  ; max_turns_per_attempt : int option
    (** Hard cap on the provider-internal agent loop turn count for a
          single subprocess attempt.  [None] means the provider does not
          impose a sub-keeper cap; [Some n] clamps the keeper-level
          [max_turns] to [n] before handing it to the underlying CLI.
          Adapter entries supply this when their runtime has a smaller
          per-attempt loop cap than the keeper-level budget.
          RFC-0058 §2.4: capability flag, not a vendor match. *)
  ; tolerates_bound_actor_fallback : bool
    (** When true, this adapter is considered a viable fallback target
          when the operator's catalog also contains an adapter that
          [requires_per_keeper_bridging_for_bound_actor_tools = true]
          Catalog static validation
          ({!Cascade_catalog_validator.bridging_required_without_fallback_issue})
          uses this flag to decide whether a bridging-required profile lacks a
          bound-actor-tolerant fallback.

          Currently set to [true] for CLI agents with native per-keeper
          MCP support: Claude Code, Gemini CLI, Kimi CLI, and the local
          Ollama runtime. HTTP-only adapters (glm-api, glm-coding-plan,
          openrouter, *-api variants) currently default to [false]; the
          legacy whitelist treated PK.Glm as tolerant but that mapping
          is unreachable via [adapter_of_provider_kind] (PK.Glm has no
          single canonical adapter), so the swap drops it pending an
          explicit reinstatement when GLM gains a per-keeper auth path.
          RFC-0058 §2.4: capability flag, not a vendor match. *)
  }

type telemetry_policy =
  { usage_reporting : reporting_policy
  ; runtime_reporting : reporting_policy
  }

type adapter =
  { canonical_name : string
  ; runtime_kind : runtime_kind
  ; auth_mode : auth_mode
  ; aliases : string list
  ; cascade_prefix : string
  ; endpoint_url : string option
  ; default_model_id : string option
  ; model_policy : model_policy
  ; tool_policy : tool_policy
  ; telemetry_policy : telemetry_policy
  ; telemetry_bucket : string option
  ; telemetry_model_prefixes : string list
  }

type gemini_direct_auth =
  | Gemini_vertex_adc of
      { project : string
      ; location : string
      }
  | Gemini_api_key
  | Gemini_auth_missing of string

(** {1 Canonical Provider Names} *)

val cn_llama : string
val cn_ollama : string
val cn_unknown_provider : string
val cn_claude : string
val cn_codex : string
val cn_gemini : string
val cn_kimi : string
val cn_claude_api : string
val cn_codex_api : string
val cn_gemini_api : string
val cn_kimi_api : string
val cn_glm : string
val cn_glm_coding_plan : string
val cn_openrouter : string
val cn_custom : string

(** {1 String Converters} *)

val string_of_runtime_kind : runtime_kind -> string
val string_of_auth_mode : auth_mode -> string

(** {1 Adapter Registry} *)

(** All registered LLM provider/runtime adapters. *)
val direct_adapters : adapter list

(** {1 Label and Provider Resolution} *)

(** Normalize a label to lowercase trimmed form. *)
val normalize_label : string -> string

(** User-facing provider label for cascade/dashboard surfaces.
    Keeps wire/config prefixes stable while presenting distinct names for
    ambiguous providers such as [glm] vs [glm-coding]. *)
val display_provider_name : string -> string

(** SSOT cascade prefix for local models. *)
val local_cascade_prefix : string

(** Build a cascade model label for a local model.
    Single entry point; other modules must not concatenate prefix manually. *)
val make_local_label : string -> string

(** SSOT string form of OAS [Provider_config.provider_kind]. *)
val string_of_provider_kind : Llm_provider.Provider_config.provider_kind -> string

(** Resolve required auth env keys for a provider kind. *)
val auth_env_keys_of_provider_kind
  :  Llm_provider.Provider_config.provider_kind
  -> string list

(** Resolve Docker worker auth env keys for a provider config. *)
val docker_auth_env_keys_of_provider_config
  :  Llm_provider.Provider_config.t
  -> string list

(** Collect all auth env keys across direct adapters. *)
val all_auth_env_keys : unit -> string list

(** Resolve an adapter by canonical name or alias. *)
val resolve_direct_adapter : string -> adapter option

(** Resolve an adapter by cascade prefix (e.g. ["gemini_cli"], ["kimi"]). *)
val resolve_adapter_by_cascade_prefix : string -> adapter option

(** Resolve the canonical name for a provider label. *)
val resolve_direct_canonical_name : string -> string option

(** Low-cardinality telemetry bucket declared on an adapter. *)
val telemetry_bucket_of_adapter : adapter -> string option

(** Resolve a low-cardinality telemetry bucket from a provider label. *)
val telemetry_bucket_of_provider_label : string -> string option

(** Resolve a low-cardinality telemetry bucket from a response model id or
    provider-prefixed model label. *)
val telemetry_bucket_of_model_id : string -> string option

(** Resolve the configured spawn executable for an agent label. *)
val resolve_spawn_executable : string -> string option

(** Check if a name is a known direct adapter label or alias. *)
val is_known_provider : string -> bool

(** Check if a name is a configured CLI-spawnable agent. *)
val is_spawnable_agent : string -> bool

(** Return canonical names of all spawnable adapters. *)
val spawnable_canonical_names : unit -> string list

(** Resolve the declared default model id for a cascade prefix. *)
val default_model_id_for_cascade_prefix
  :  ?getenv:(string -> string option)
  -> string
  -> string option

(** Resolve declared auto-model expansion for a cascade prefix. *)
val auto_models_for_cascade_prefix
  :  ?getenv:(string -> string option)
  -> string
  -> string list option

(** Returns true if the provider uses runtime discovery (e.g. live /props probe). *)
val requires_discovery : string -> bool

(** Returns true if the provider is self-hosted and always available. *)
val is_local_provider : string -> bool

(** [is_http_probe_capable_kind kind] is [true] when the provider
    serves an HTTP capacity probe endpoint that
    {!Cascade_http_probe} can poll (currently the ollama [/api/ps]
    schema). Caller-side capacity-register paths consult this flag
    to decide whether to register the cfg's [base_url] with the
    probe registry.

    RFC-0058 Phase 5.6: capability predicate, not a vendor match.
    Adding vLLM / lmstudio support means editing this one boundary
    site, never the keeper layer. *)
val is_http_probe_capable_kind :
  Llm_provider.Provider_config.provider_kind -> bool

(** {1 Model Label Resolution} *)

(** Default fallback label for local runtime when no preferred models exist. *)
val default_local_fallback_label : unit -> string

(** Preferred execution model labels in priority order. *)
val preferred_execution_model_labels : unit -> string list

(** Preferred verifier model labels in priority order. *)
val preferred_verifier_model_labels : unit -> string list

(** Configured default model label (first from MASC_DEFAULT_CASCADE or
    MASC_DEFAULT_PROVIDER/MASC_DEFAULT_MODEL). *)
val configured_default_model_label_result : unit -> (string, string) result

(** Configured verifier model label (MASC_DEFAULT_VERIFIER_MODEL fallback to default). *)
val configured_verifier_model_label_result : unit -> (string, string) result

(** Default model label(s) result. *)
val default_model_labels_result : unit -> (string list, string) result

(** First default model label. *)
val default_model_label_result : unit -> (string, string) result

(** Extract provider prefix from a "provider:model" label. *)
val provider_prefix_of_label_result : string -> (string, string) result

(** Classify a model label to a provider name for telemetry grouping.

    Explicit ["provider:model"] labels use the adapter registry prefix. Bare
    model ids are classified only when the caller supplies typed
    [provider_kind] telemetry; otherwise this returns ["unknown"] rather than
    guessing from vendor-looking substrings. *)
val provider_of_model_label
  :  ?provider_kind:Llm_provider.Provider_config.provider_kind
  -> string
  -> string

(** Whether the model label resolves to a provider that supports runtime MCP
    HTTP headers. Bare labels are accepted only when they exactly match an
    adapter/cascade registry entry or when [provider_kind] supplies the typed
    provider boundary. *)
val supports_runtime_mcp_http_headers_for_model_label
  :  ?provider_kind:Llm_provider.Provider_config.provider_kind
  -> string
  -> bool

(** True when the provider emits no usage tokens in its standard response.
    Used by metrics coverage gating so text-only turns against CLI-class
    providers that strip usage do not count as coverage gaps. *)
val is_structurally_unmetered_provider : string -> bool

(** Provider prefix of the default model label. *)
val default_model_provider_prefix_result : unit -> (string, string) result

(** Override the model portion of the default model label. *)
val default_model_override_label_result : string -> (string, string) result

(** {1 Llama Model Resolution} *)

val explicit_llama_model_id_result : unit -> (string, string) result
val explicit_llama_model_label_result : unit -> (string, string) result

(** {1 Ollama} *)

val bare_ollama_migration_message : unit -> string
val is_bare_ollama_label : string -> bool

(** {1 Auth} *)

(** Check whether a provider has auth credentials configured. *)
val provider_auth_available : string -> bool

(** Derive auth_kind string for a provider canonical name. *)
val auth_kind_for_canonical_name : string -> string

(** Cascade prefix from adapter record. *)
val cascade_prefix_of_adapter : adapter -> string

(** Endpoint URL from adapter record. *)
val endpoint_url_of_adapter : adapter -> string option

(** Best-effort mapping from Provider_registry/OAS [provider_kind] to a
    MASC cascade prefix. *)
val cascade_prefix_of_provider_kind : Llm_provider.Provider_config.provider_kind -> string

(** {1 Gemini Auth} *)

val gemini_direct_available : unit -> bool
val resolve_gemini_direct_auth : unit -> gemini_direct_auth

(** Compute the Vertex AI OpenAI-compatible endpoint URL. *)
val gemini_vertex_openai_base_url : project:string -> location:string -> string

(** Resolve the concrete provider adapter for a provider config. *)
val adapter_of_provider_config : Llm_provider.Provider_config.t -> adapter option

(** Resolve the concrete provider adapter for an OAS [provider_kind].
    Used by call sites that only have the typed kind (no full config)
    and need adapter-level capability flags. RFC-0058 §2.4 boundary. *)
val adapter_of_provider_kind
  :  Llm_provider.Provider_config.provider_kind
  -> adapter option

(** Stable provider label/cascade prefix for a provider config. *)
val provider_label_of_config : Llm_provider.Provider_config.t -> string

(** Apply a wire-layer overlay to an SDK [provider] config.

    {!Agent_sdk.Provider.config_of_provider_config} maps an
    [OpenAI_compat] cfg to [Local] when no transport hints exist on the
    SDK side, which drops the configured non-default [request_path] and
    auth token. [apply_wire_overlay] detects that under-routing and
    rewraps the [provider] field as [OpenAICompat] with the cfg's
    [base_url], [api_key]-derived auth header, custom [path], and
    [static_token].

    All other shapes pass through unchanged. This is the single
    boundary site that inspects [provider_cfg.kind] alongside the
    SDK's [provider] variant; keeper-layer callers
    ({!Cascade_agent_context.default_config}) no longer pattern-match on
    either. *)
val apply_wire_overlay
  :  provider_cfg:Llm_provider.Provider_config.t
  -> Agent_sdk.Provider.config
  -> Agent_sdk.Provider.config

(** Stable key for cascade health and circuit-breaker state.
    Most providers are keyed at provider level. Local OpenAI-compatible
    endpoints include model and base URL so independent loopback runtimes can
    fail over without sharing cooldown state. *)
val provider_health_key_of_config : Llm_provider.Provider_config.t -> string

(** Stable model-level key for model-specific cascade health state. *)
val provider_model_health_key_of_config : Llm_provider.Provider_config.t -> string

(** User-facing provider label for a provider config. *)
val display_provider_name_of_config : Llm_provider.Provider_config.t -> string

(** Build the stable "provider:model" label for a provider config. *)
val model_label_of_config : Llm_provider.Provider_config.t -> string

(** Whether the resolved adapter declares runtime MCP HTTP header support. *)
val supports_runtime_mcp_http_headers_for_config : Llm_provider.Provider_config.t -> bool

(** Whether the resolved adapter requires explicit per-keeper bridging in
    order to carry a runtime MCP policy that uses bound-actor tools.

    The cascade filter uses this flag to gate entries without dispatching on
    provider name. *)
val requires_per_keeper_bridging_for_bound_actor_tools_for_config
  :  Llm_provider.Provider_config.t
  -> bool

(** RFC-0058 §2.4 SSOT bridge: build a [tool_policy] from a cascade-decl
    [cascade_capabilities] (the TOML-parsed shape).

    [None] (no [[providers.<id>.capabilities]] sub-table) returns the
    conservative [no_tool_http_headers] baseline (a private [tool_policy]
    record inside [provider_adapter.ml]; not exported by this signature).

    [Some c] maps the [tool_policy]-relevant subset of
    [cascade_capabilities]:

    - [supports_runtime_mcp_http_headers]
    - [requires_per_keeper_bridging_for_bound_actor_tools]
    - [identity_runtime_mcp_header_keys]
    - [argv_prompt_preflight]
    - [uses_anthropic_caching]
    - [max_turns_per_attempt]
    - [tolerates_bound_actor_fallback]

    The remaining [cascade_capabilities] fields
    ([supports_inline_tools], [supports_runtime_mcp_tools],
    [supports_runtime_tool_events]) describe runtime tool / event
    surfaces and are intentionally not represented in [tool_policy];
    they are consumed elsewhere (e.g. [Provider_tool_support]).

    Schema-additive primitive; no callers yet. Future caller cutover
    will route [adapter_of_provider_config] through this bridge so
    [config/cascade.toml] becomes the lookup root and the 13 hardcoded
    [tool_policy = ...] records collapse into a single cascade-toml-
    driven path. *)
val tool_policy_of_cascade_capabilities
  :  Cascade_declarative_types.cascade_capabilities option
  -> tool_policy

(** Same as {!requires_per_keeper_bridging_for_bound_actor_tools_for_config}
    but takes a typed [provider_kind] directly.  Used by call sites that do
    not have a full {!Llm_provider.Provider_config.t} (e.g. keeper-bound
    actor authorisation resolution, cascade catalog static validation).
    Returns [false] when no adapter resolves for [kind].
    RFC-0058 §2.4: capability flag, not a vendor match. *)
val requires_per_keeper_bridging_for_bound_actor_tools_for_kind
  :  Llm_provider.Provider_config.provider_kind
  -> bool

(** Whether the resolved adapter for [kind] is a viable fallback when
    the catalog also contains a bridging-required adapter.
    Returns [false] when no adapter resolves for [kind] (including
    PK.Glm and PK.OpenAI_compat, which have no single canonical adapter).
    Used by {!Cascade_catalog_validator.bridging_required_without_fallback_issue}.
    RFC-0058 §2.4: capability flag, not a vendor match. *)
val tolerates_bound_actor_fallback_for_kind
  :  Llm_provider.Provider_config.provider_kind
  -> bool

(** OAS-level capabilities for a provider config.  Delegates provider/model
    capability truth to [Agent_sdk.Provider_runtime_binding] so MASC consumers
    do not own provider-kind capability tables. *)
val oas_capabilities_of_config
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Capabilities.capabilities

(** Whether a runtime-MCP HTTP header key is acceptable for the resolved
    adapter, even when general HTTP-header support is off.  Covers the
    per-adapter identity header carve-out
    (for example [x-masc-agent-name] and [x-masc-keeper-name]).
    Returns [true] unconditionally for adapters with
    [supports_runtime_mcp_http_headers = true]. *)
val accepts_runtime_mcp_http_header_for_config
  :  Llm_provider.Provider_config.t
  -> string
  -> bool

(** {1 Misc} *)

val default_cli_agent_name : unit -> string

(** Build "provider:model" label, returns [None] if model is empty. *)
val provider_model_label : string -> string -> string option

(** Extract the env var name from an adapter's [auth_mode], if any. *)
val auth_env_var_of_adapter : adapter -> string option

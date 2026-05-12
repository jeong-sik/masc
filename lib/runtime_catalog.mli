(** Runtime_catalog — MASC provider compatibility overlay, auth resolution,
    voice bridge, and cascade label construction.

    Generic provider connection metadata and capability facts belong to
    OAS Provider_registry/Provider_catalog. This module retains MASC-local
    overlays that OAS deliberately does not own: cascade labels, spawn keys,
    runtime-MCP policy quirks, telemetry policy, auth display, and voice
    defaults.

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

type reporting_policy =
  | Reported
  | Missing_by_design
  | Unknown

type model_policy =
  { default_model_env : string option
  ; default_model_fallback : string option
  ; family : model_family
  }

type tool_policy =
  { supports_runtime_mcp_http_headers : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
    (** When true, this provider's runtime cannot inject per-keeper auth
          headers natively. Bound-actor runtime MCP tools therefore require
          explicit per-keeper bridging at the cascade layer; otherwise the
          filter must reject the policy for this provider.

          Codex CLI is currently the only adapter that sets this to [true]:
          its cached login does not allow per-keeper authorization headers
          to be injected on each request without bridging. *)
  ; identity_runtime_mcp_header_keys : string list
    (** Header keys the provider can carry even when
          [supports_runtime_mcp_http_headers = false].  Empty for most
          providers.  Codex CLI carries [authorization] (via
          [bearer_token_env_var]) plus the non-secret MASC identity
          headers ([x-masc-agent-name], [x-masc-keeper-name]).
          Keys are matched case-insensitively after trimming. *)
  ; argv_prompt_preflight : bool
    (** When true, callers must run a prompt argv/context-window preflight
          before spawning a turn (the runtime serialises the full prompt on
          a single argv vector and rejects oversize input). Codex CLI's
          [codex exec] subprocess transport is the canonical case.
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
          Only Claude Code currently sets this (loop hard cap = 30).
          RFC-0058 §2.4: capability flag, not a vendor match. *)
  ; tolerates_bound_actor_fallback : bool
    (** When true, this adapter is considered a viable fallback target
          when the operator's catalog also contains an adapter that
          [requires_per_keeper_bridging_for_bound_actor_tools = true]
          (e.g. Codex CLI). Catalog static validation
          ({!Cascade_catalog_validator.codex_with_bound_actor_only_issue})
          uses this flag to decide whether a "Codex CLI present without a
          bound-actor-tolerant fallback" warning should fire.

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

type voice_transport =
  | Voice_openai_compat
  | Voice_elevenlabs_direct
  | Voice_mcp

type adapter =
  { canonical_name : string
  ; runtime_kind : runtime_kind
  ; auth_mode : auth_mode
  ; aliases : string list
  ; spawn_key : string option
  ; cascade_prefix : string
  ; default_voice : string option
  ; endpoint_url : string option
  ; default_model_id : string option
  ; model_policy : model_policy
  ; tool_policy : tool_policy
  ; telemetry_policy : telemetry_policy
  }

type voice_adapter =
  { canonical_name : string
  ; transport : voice_transport
  ; auth_mode : auth_mode
  ; aliases : string list
  }

type voice_http_request =
  { url : string
  ; headers : (string * string) list
  ; body_json : Yojson.Safe.t
  }

type voice_stt_request =
  { url : string
  ; headers : (string * string) list
  ; form_fields : (string * string) list
  ; file_field : string * string
  }

type gemini_direct_auth =
  | Gemini_vertex_adc of
      { project : string
      ; location : string
      }
  | Gemini_api_key
  | Gemini_auth_missing of string

type auth_detail =
  { auth_kind : string
  ; status : string
  ; available : bool
  ; supports_run : bool
  ; endpoint_url : string option
  ; note : string option
  }

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
val string_of_voice_transport : voice_transport -> string

(** {1 Adapter Registry} *)

(** All registered LLM provider/runtime adapters. *)
val direct_adapters : adapter list

(** All registered voice runtime entries. *)
val voice_adapters : voice_adapter list

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

(** Resolve spawn_key for an agent label. *)
val resolve_spawn_key : string -> string option

(** Check if a name is a known direct adapter label or alias. *)
val is_known_provider : string -> bool

(** Check if a name is a CLI-spawnable agent (has a spawn_key). *)
val is_spawnable_agent : string -> bool

(** Return canonical names of all spawnable adapters. *)
val spawnable_canonical_names : unit -> string list

(** Resolve the declared default model id for a cascade prefix. *)
val default_model_id_for_cascade_prefix
  :  ?getenv:(string -> string option)
  -> string
  -> string option

(** Resolve auto-model expansion for a provider canonical name/alias.
    Expansion comes from an explicit [MASC_<CASCADE_PREFIX>_AUTO_MODELS]
    environment override, or from an OAS catalog-backed provider family
    such as ZAI/GLM. CLI providers do not carry built-in model lists here;
    absent an explicit override, their ["auto"] selector is passed through
    to the runtime. *)
val auto_models_for_provider
  :  ?getenv:(string -> string option)
  -> string
  -> string list option

(** Resolve auto-model expansion for a cascade prefix. *)
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

(** Per-provider per-attempt timeout bounds.

    [min_timeout_s] is the floor below which an attempt timeout is
    never set; [max_timeout_s] is the ceiling above which an attempt
    cannot block. *)
type timeout_bounds =
  { min_timeout_s : float option
  ; max_timeout_s : float option
  }

(** [timeout_bounds_of_kind kind] is the per-provider attempt timeout
    policy.  Encapsulates the only [match provider_cfg.kind] site
    that used to live in keeper-layer driver helpers; new providers
    add an arm here, not at the call site.

    RFC-0058 Phase 5.6: vendor-specific operational tunables live
    inside the adapter boundary, not the keeper turn-driver. *)
val timeout_bounds_of_kind :
  Llm_provider.Provider_config.provider_kind -> timeout_bounds

(** {1 Voice Adapter Resolution} *)

val resolve_voice_adapter : string -> voice_adapter option
val voice_adapter_for_endpoint : Voice_config.endpoint -> voice_adapter
val voice_adapter_for_endpoint_kind : Voice_config.endpoint_kind -> voice_adapter
val voice_adapter_labels : voice_adapter -> string list
val voice_endpoint_matches_provider_label : string -> Voice_config.endpoint -> bool

val select_voice_endpoints
  :  ?provider:string
  -> Voice_config.endpoint list
  -> Voice_config.endpoint list

(** Resolve auth env var name for a voice adapter, with optional endpoint override. *)
val voice_auth_env_name : ?endpoint_api_key_env:string -> voice_adapter -> string option

val voice_endpoint_auth_env_name : Voice_config.endpoint -> string option
val voice_transport_supports_http_tts : voice_adapter -> bool
val voice_endpoint_supports_http_tts : Voice_config.endpoint -> bool

(** All agent voices as [(canonical_name, voice_name)] pairs. *)
val all_agent_voices : unit -> (string * string) list

(** {1 Voice Session URLs} *)

val default_voice_session_url : path:string -> string

val voice_session_endpoint_result
  :  Voice_config.t
  -> (Voice_config.endpoint, string) result

val voice_session_mcp_url_of_endpoint : Voice_config.endpoint -> (string, string) result

val voice_session_health_url_of_endpoint
  :  Voice_config.endpoint
  -> (string, string) result

(** {1 Voice HTTP Requests} *)

val voice_http_request_for_tts
  :  Voice_config.endpoint
  -> api_key:string
  -> message:string
  -> voice:string
  -> model:string
  -> tuning:Voice_config.voice_tuning
  -> (voice_http_request, string) result

val voice_stt_request_for_endpoint
  :  Voice_config.endpoint
  -> api_key:string
  -> audio_file:string
  -> model:string
  -> (voice_stt_request, string) result

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

(** Provider-agnostic auth detail for dashboard display. *)
val auth_detail_of_provider : string -> auth_detail

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

(** Resolve the concrete runtime catalog entry for a provider config. *)
val adapter_of_provider_config : Llm_provider.Provider_config.t -> adapter option

(** Resolve the concrete runtime catalog entry for an OAS [provider_kind].
    Used by call sites that only have the typed kind (no full config)
    and need runtime-level capability flags. RFC-0058 §2.4 boundary. *)
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
    ({!Keeper_agent_context.default_config}) no longer pattern-match on
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

    Currently only [codex_cli] returns [true]; the cascade filter uses this
    flag to gate entries without dispatching on provider name. *)
val requires_per_keeper_bridging_for_bound_actor_tools_for_config
  :  Llm_provider.Provider_config.t
  -> bool

(** RFC-0058 §2.4 SSOT bridge: build a [tool_policy] from a cascade-decl
    [cascade_capabilities] (the TOML-parsed shape).

    [None] (no [[providers.<id>.capabilities]] sub-table) returns the
    conservative [no_tool_http_headers] baseline (a private [tool_policy]
    record inside [runtime_catalog.ml]; not exported by this signature).

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
    the catalog also contains a bridging-required adapter (Codex CLI).
    Returns [false] when no adapter resolves for [kind] (including
    PK.Glm and PK.OpenAI_compat, which have no single canonical adapter).
    Used by {!Cascade_catalog_validator.codex_with_bound_actor_only_issue}.
    RFC-0058 §2.4: capability flag, not a vendor match. *)
val tolerates_bound_actor_fallback_for_kind
  :  Llm_provider.Provider_config.provider_kind
  -> bool

(** Whether a runtime-MCP HTTP header key is acceptable for the resolved
    adapter, even when general HTTP-header support is off.  Covers the
    Codex CLI identity header carve-out
    ([authorization], [x-masc-agent-name], [x-masc-keeper-name]).
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

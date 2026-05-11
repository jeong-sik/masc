(** Declarative cascade configuration types (RFC-0058 v2).

    5-layer TOML schema internal representation:
    Layer 1: [providers.*]     — How to connect
    Layer 2: [models.*]        — What it can do
    Layer 3: [<p>.<m>]         — How much, at what cost
    Layer 4: [<p>.<m>.<a>]     — Per-use overrides
    Layer 5: [tier.*] + [tier-group.*] + [routes] — Routing strategy

    Code knows API formats, not provider brands. See RFC-0058 §2.1.

    All type names are prefixed with [cascade_] to avoid collision with
    identically-named types in the main masc_mcp library. *)

(** {1 API Format & Transport} *)

type cascade_api_format =
  | Messages_api
  | Chat_completions_api
  | Ollama_api
[@@deriving show, eq]

type cascade_transport =
  | Http of string
  | Cli of string
[@@deriving show, eq]

type cascade_credential =
  | Env of string
  | File of string
  | Inline of string
[@@deriving show, eq]

(** {1 Layer 1: Providers} *)

(** Per-provider liveness class — RFC-0058 §3.2.1 (Phase 5.2).
    Schema only at this phase; the field is parsed and validated but
    not yet consumed. Intended to replace the hardcoded cascade-prefix
    → budget match table in
    [Cascade_attempt_liveness_config.budget_for_label] in a follow-up
    phase. *)
type cascade_liveness_class =
  | Cloud_fast
  | Cloud_thinking
  | Local_27b
  | Local_70b_plus
[@@deriving show, eq]

(** Per-provider runtime + behavioral capabilities — RFC-0058 §2.4 +
    Phase 5.1 (caller cutover prep, A.1) + §3.2 Phase 5.6 (tool/event support).

    Schema-additive in this PR; no callers consume the fields yet.
    Phase 5.1 caller cutover follows in A.3 (cascade_transport,
    Provider_tool_support, Cascade_error_classify, Keeper_usage_trust);
    Phase 5.6 caller cutover replaces [Cascade_config.headers_with_auth]
    variant match. *)
type cascade_capabilities =
  { supports_inline_tools : bool
  ; supports_runtime_mcp_tools : bool
  ; supports_runtime_tool_events : bool
  ; supports_runtime_mcp_http_headers : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
  ; identity_runtime_mcp_header_keys : string list
  ; argv_prompt_preflight : bool
  ; uses_anthropic_caching : bool
  ; max_turns_per_attempt : int option
  ; tolerates_bound_actor_fallback : bool
  }
[@@deriving show, eq]

val cascade_capabilities_default : cascade_capabilities

type cascade_provider =
  { id : string
  ; display_name : string
  ; api_format : cascade_api_format
  ; transport : cascade_transport
  ; is_non_interactive : bool
  ; credentials : cascade_credential option
  ; liveness_class : cascade_liveness_class option
  ; capabilities : cascade_capabilities option
    (** Caller cutover (A.3) replaces:
      - [Llm_provider.Capabilities.*] variant defaults (Phase 5.6, tool/event fields)
      - [Cascade_transport] / [Provider_tool_support] / [Cascade_error_classify] /
        [Keeper_usage_trust] closed-variant matches (Phase 5.1, dispatch fields) *)
  ; headers : (string * string) list option
    (** Reserved schema (Phase 5.6 prep). Additional HTTP headers per
      provider, e.g. [("anthropic-version", "2023-06-01")] for Anthropic
      HTTP API. Sorted by key for deterministic show/eq. [None] means
      no [\[providers.<id>.headers\]] sub-table; [Some \[\]] means
      declared but empty (or all entries rejected as non-string).
      Caller cutover replaces [Cascade_config.headers_with_auth] variant match. *)
  }
[@@deriving show, eq]

(** {1 Layer 2: Models} *)

(** Wire-format for controlling thinking/reasoning on OpenAI-compat
    backends. Mirrors OAS [Llm_provider.Capabilities.thinking_control_format].

    The three variants describe how an OpenAI-compat backend's request
    body should encode "enable thinking":
    - [No_thinking_control]: no reasoning surface at all (legacy GPT-4o,
      Anthropic CLI wrappers).
    - [Thinking_object]: DeepSeek/GLM-style \{"thinking":\{"type":"enabled"\}\}.
    - [Chat_template_kwargs]: llama-server-style
      \{"chat_template_kwargs":\{"enable_thinking":bool\}\}.

    Recorded on the model because the same physical model can be served
    by backends with different thinking-control wire shapes (e.g., qwen3
    via llama-server vs via DeepSeek's API), so the model entry must
    pin which shape the backend expects. *)
type cascade_thinking_control_format =
  | No_thinking_control
  | Thinking_object
  | Chat_template_kwargs
[@@deriving show, eq]

(** Per-model capabilities — RFC-0058 Model axis M1 + M1b (Phase 5.3 prep).

    Mirrors OAS {!Llm_provider.Capabilities.capabilities} for the fields
    that real OAS callers actually branch on (measured via grep on
    [.supports_*] / [.max_*] / [.emits_*] field access — 13 fields with
    ≥4 access sites, 6 more shipped pre-emptively for cascade routing
    completeness).

    Schema-additive: no callers consume the fields in this PR. M2
    follow-up wires OAS [for_model_id_static], which currently
    substring-matches on the upstream API model identifier (e.g.
    [\"claude-sonnet-4-6\"] — Llm_provider.Capabilities.for_model_id
    receives the api-name, not the cascade [\[models.<id>\]] key
    [\"sonnet\"]), to read these fields via {!model_capabilities_for_id} —
    keyed on the cascade [<id>] (the cascade key, not the api-name).

    Field selection excludes fields already present on
    {!cascade_model_spec} ([tools_support] mirrors
    [Capabilities.supports_tools], [thinking_support] mirrors
    [supports_reasoning], [max_context] mirrors [max_context_tokens],
    [streaming] is the abstract gate distinct from
    {!supports_native_streaming}'s wire-protocol claim) — these are not
    duplicated to avoid two-SSOT drift. *)
type cascade_model_capabilities =
  { max_output_tokens : int option
  ; (* Tool use *)
    supports_parallel_tool_calls : bool
  ; supports_tool_choice : bool
  ; (* Thinking / reasoning *)
    supports_extended_thinking : bool
  ; supports_reasoning_budget : bool
  ; thinking_control_format : cascade_thinking_control_format
  ; (* Multimodal *)
    supports_image_input : bool
  ; supports_audio_input : bool
  ; supports_video_input : bool
  ; supports_multimodal_inputs : bool
  ; (* Output format *)
    supports_response_format_json : bool
  ; supports_structured_output : bool
  ; (* Protocol *)
    supports_native_streaming : bool
  ; supports_caching : bool
  ; supports_prompt_caching : bool
  ; prompt_cache_alignment : int option
  ; (* Sampling parameters *)
    supports_top_k : bool
  ; supports_min_p : bool
  ; supports_seed : bool
  ; (* Usage reporting *)
    emits_usage_tokens : bool
  ; (* Advanced modalities *)
    supports_computer_use : bool
  }
[@@deriving show, eq]

val cascade_model_capabilities_default : cascade_model_capabilities

type cascade_model_spec =
  { id : string
  ; api_name : string
  ; tools_support : bool
  ; max_context : int
  ; thinking_support : bool
  ; max_thinking_budget : int option
  ; streaming : bool
  ; capabilities : cascade_model_capabilities option
    (** M1 schema-additive. [None] means
          [\[models.<id>.capabilities\]] sub-table absent — M2
          callers (the model-axis cutover) treat this as
          {!cascade_model_capabilities_default}. Distinct from the
          A.3 provider-capabilities cutover, which consumes
          [cascade_provider.capabilities]. *)
  ; match_prefixes : string list
    (** M1c. Prefixes for matching against requested model_id strings.
          Empty list = the spec matches only exact equality to
          [api_name]. Multi-element list = the spec matches any
          model_id starting with one of the listed prefixes.

          Used by {!model_spec_for_api_name} and
          {!model_capabilities_for_api_name} to replicate the
          longest-prefix-first semantics of OAS
          [Llm_provider.Capabilities.for_model_id_static]'s if/elsif
          tree without OAS knowing model names. *)
  }
[@@deriving show, eq]

(** {1 Layer 3: Bindings (Provider×Model)} *)

type cascade_binding =
  { provider_id : string
  ; model_id : string
  ; is_default : bool
  ; max_concurrent : int
  ; price_input : float option
  ; price_output : float option
  ; keep_alive : string option
  ; num_ctx : int option
  }
[@@deriving show, eq]

(** {1 Layer 4: Aliases} *)

type cascade_alias =
  { provider_id : string
  ; model_id : string
  ; name : string
  ; max_input : int option
  ; max_output : int option
  ; temperature : float option
  ; thinking_enabled : bool option
  ; thinking_budget : int option
  }
[@@deriving show, eq]

(** {1 Strategy} *)

type cascade_strategy =
  | Failover
  | Capacity_aware
  | Weighted_random
  | Circuit_breaker_cycling
  | Priority_tier
  | Sticky
  | Round_robin
[@@deriving show, eq]

(** {1 Strategy-specific parameter types} *)

type cascade_cycle_policy =
  { max_cycles : int
  ; backoff_base_ms : int
  ; backoff_cap_ms : int
  }
[@@deriving show, eq]

type cascade_scoring_params =
  { latency_baseline_ms : float
  ; rate_limit_recency_window_s : float
  ; rate_limit_decay_base : float
  ; rate_limit_skip_after : int
  ; server_error_recency_window_s : float
  ; server_error_decay_base : float
  ; server_error_skip_after : int
  }
[@@deriving show, eq]

(** {1 Layer 5: Tiers, Tier-Groups, Routes} *)

type cascade_tier =
  { name : string
  ; members : string list
  ; strategy : cascade_strategy
  ; max_concurrent : int option
  ; cycle_policy : cascade_cycle_policy option
  ; sticky_ttl_ms : int option
  ; scoring_params : cascade_scoring_params option
  }
[@@deriving show, eq]

type cascade_tier_group =
  { name : string
  ; tiers : string list
  ; strategy : cascade_strategy
  ; fallback : bool
  }
[@@deriving show, eq]

type cascade_route =
  { name : string
  ; target : string
  }
[@@deriving show, eq]

(** {1 Top-level Config} *)

type cascade_config =
  { providers : cascade_provider list
  ; models : cascade_model_spec list
  ; bindings : cascade_binding list
  ; aliases : cascade_alias list
  ; tiers : cascade_tier list
  ; tier_groups : cascade_tier_group list
  ; routes : cascade_route list
  ; system_targets : cascade_route list
  }
[@@deriving show, eq]

(** {1 Lookup helpers} *)

val provider_of_id : cascade_config -> string -> cascade_provider option

(** [capabilities_for_provider_id cfg id] returns the cascade-declared
    capabilities for the provider with id [id]. Resolves [None] in two
    distinct cases collapsed into one option:
    - The provider id is not declared in [cfg.providers].
    - The provider is declared but ships no [\[providers.<id>.capabilities\]]
      sub-table (parser yields [capabilities = None]).

    A.3 callers treat [None] as "use defaults" — equivalent to
    {!cascade_capabilities_default}. The two cases are not distinguished
    here because A.3 callers cannot remediate either: an id misspelled
    in code is a static bug, and a provider that opts out of declaring
    capabilities relies on runtime defaults.

    Phase 5.1 A.3 caller cutover uses this lookup to replace closed-variant
    [match provider_kind with PK.Codex_cli | PK.Claude_code | ... -> ...]
    patterns. *)
val capabilities_for_provider_id : cascade_config -> string -> cascade_capabilities option

(** [model_capabilities_for_id cfg id] returns the cascade-declared
    per-model capabilities for the model with id [id]. [None] in two
    collapsed cases (same rationale as
    {!capabilities_for_provider_id}):
    - model id not declared in [cfg.models]
    - model declared but ships no [\[models.<id>.capabilities\]] sub-table

    M2 caller cutover wires OAS [for_model_id_static] to read these
    fields instead of model-id substring match. *)
val model_capabilities_for_id
  :  cascade_config
  -> string
  -> cascade_model_capabilities option

val model_of_id : cascade_config -> string -> cascade_model_spec option

val model_spec_for_api_name
  :  cascade_config
  -> string
  -> cascade_model_spec option
(** [model_spec_for_api_name cfg model_id] returns the cascade.toml
    model spec that best matches a requested [model_id] string.

    Resolution rule (longest-prefix-first):
    + If any spec's [api_name] equals [model_id], return that spec
      (a synthetic prefix of full length always beats any other).
    + Otherwise, scan every spec's {!cascade_model_spec.match_prefixes}
      and return the spec whose matched prefix is longest. Ties on
      length resolve to the first-declared entry.
    + Returns [None] if no spec matches.

    Replaces the substring if/elsif tree in OAS
    [Llm_provider.Capabilities.for_model_id_static] with cascade.toml
    as the SSOT — the OAS function becomes a thin wrapper invoking
    this lookup.

    M2 caller cutover wires OAS [for_model_id_static] to this. *)

val model_capabilities_for_api_name
  :  cascade_config
  -> string
  -> cascade_model_capabilities option
(** [model_capabilities_for_api_name cfg model_id] returns the
    per-model capabilities of the spec resolved via
    {!model_spec_for_api_name}. [None] if either no spec matches the
    requested [model_id] or the resolved spec declared no
    [\[models.<id>.capabilities\]] sub-table.

    M2 cutover replaces OAS substring-on-model-id capability
    derivation with this lookup. *)
val binding_of_key : cascade_config -> string -> string -> cascade_binding option
val alias_of_key : cascade_config -> string -> string -> string -> cascade_alias option
val binding_key : cascade_binding -> string
val alias_key : cascade_alias -> string

(** Cascade configuration: named provider profiles with JSON hot-reload
    and discovery-aware health filtering.

    Consumers define named cascade profiles
    mapping to ordered lists of providers. This module handles:
    - Parsing "provider:model" strings into {!Llm_provider.Provider_config.t}
    - Loading profiles from a JSON config file (mtime-based hot-reload)
    - Filtering providers by local endpoint health via {!Discovery}
    - Convenience cascade execution combining the above

    @since 0.59.0

    @stability Internal
    @since 0.93.1 *)

(** {1 Model Alias Resolution} *)

(** Resolve a GLM model alias to the concrete API model ID.
    - ["auto"] → env var [ZAI_DEFAULT_MODEL] or ["glm-5.1"]
    - ["flash"] → ["glm-4.7-flashx"]
    - ["turbo"] → ["glm-5-turbo"]
    - ["vision"] → ["glm-4.6v"]
    - Concrete IDs pass through unchanged.
    @since 0.89.1 *)
val resolve_glm_model_id : string -> string

(** Resolve "auto" and aliases to concrete model IDs for any provider.
    Cloud providers resolve aliases; local providers pass through.
    @since 0.89.1 *)
val resolve_auto_model_id : string -> string -> string

(** {1 Model String Parsing} *)

(** Parse a "provider:model_id" string into a {!Llm_provider.Provider_config.t}.

    Supported providers are determined by {!Llm_provider.Provider_registry.default}.
    Built-in: llama, claude, gemini, glm, openrouter, custom.

    Returns [None] when the provider is unknown or the required API key
    env var is not set (provider is unavailable). *)
val parse_model_string :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  ?supports_tool_choice_override:bool ->
  string -> Llm_provider.Provider_config.t option
(** [api_key_env_overrides] defaults to [[]]. When non-empty, it overrides
    the registry default API key env var for matching providers; see
    {!parse_model_strings} for format details. Empty-string entries fall
    through to the next level of the resolution chain.

    [supports_tool_choice_override] is forwarded to
    {!Llm_provider.Provider_config.make}. [None] leaves the per-kind default
    from {!Llm_provider.Capabilities} in place; [Some b] forces [b].

    @since 0.122.0 api_key_env_overrides parameter added
    @since 0.150.0 supports_tool_choice_override parameter added *)

(** Parse a {!Cascade_config_loader.weighted_entry} into a
    {!Llm_provider.Provider_config.t}. Forwards
    [entry.supports_tool_choice] as the
    [supports_tool_choice_override]. The [weight] is not part of
    Provider_config; it drives cascade ordering separately.

    @since 0.150.0 *)
val parse_weighted_entry :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  Cascade_config_loader.weighted_entry ->
  Llm_provider.Provider_config.t option

type weighted_entry_drop =
  | Drop_unregistered_scheme of { model : string; scheme : string }
  | Drop_unavailable_scheme of { model : string; scheme : string }
  | Drop_invalid_syntax of string

(** Like {!parse_weighted_entry}, but preserves the reason a candidate was
    rejected so callers can surface actionable validation errors.

    @since 0.150.0 *)
val parse_weighted_entry_diag :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  Cascade_config_loader.weighted_entry ->
  (Llm_provider.Provider_config.t, weighted_entry_drop) result

(** Parse a list of weighted entries, dropping ones that cannot produce a
    provider config. Preserves input order.

    Drops are categorised (unregistered provider scheme, unavailable
    provider, invalid syntax) and logged once per call through
    {!Log.Misc}: unregistered schemes and invalid syntax are promoted to
    ERROR because they usually indicate cascade.json drift or a stale
    binary linked against an older provider registry. Unavailable
    schemes (missing API key, missing CLI binary) log at WARN. If every
    entry is filtered out the call escalates to an additional ERROR so
    zero-provider cascades surface at load time rather than silently
    producing no responses.

    [cascade_name] is included in diagnostics when supplied.

    @since 0.150.0 *)
val parse_weighted_entries :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  ?cascade_name:string ->
  Cascade_config_loader.weighted_entry list ->
  Llm_provider.Provider_config.t list

val order_weighted_entries :
  ?rand_int:(int -> int) ->
  ?rotation_scope:string ->
  Cascade_config_loader.weighted_entry list ->
  Cascade_config_loader.weighted_entry list
(** Order weighted entries using the same health-adjusted runtime logic as
    {!resolve_model_strings}. Exposed so runtime-authoritative catalog
    snapshots can preserve dynamic health ordering without rereading raw
    [cascade.json].

    When [rotation_scope] is provided, each [provider:auto] expansion is
    round-robined independently within that scope before the usual
    weight/health ordering is applied. *)

(** Like {!parse_model_string} but returns a [Result] with a diagnostic
    error message explaining why parsing failed (unknown provider, missing
    API key, bad format).  Intended for MCP tool boundaries where callers
    need to report the reason back to the user.

    @since 0.81.0 *)
val parse_model_string_exn :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  string -> (Llm_provider.Provider_config.t, string) result

(** Expand provider:auto specs that map to multiple models.
    ["glm:auto"] expands to ["glm:glm-5.1"; "glm:glm-5-turbo"; ...].
    CLI specs such as ["gemini_cli:auto"], ["codex_cli:auto"], and
    ["claude_code:auto"] expand through their provider-specific
    auto-model lists. Other specs pass through unchanged. *)
val expand_auto_models : string list -> string list

(** Parse multiple model strings, skipping unavailable ones.
    Internally calls {!expand_auto_models} before parsing.

    When [api_key_env_overrides] is provided, it overrides the default
    API key env var for matching providers. The list maps provider names
    (or ["*"] for all) to env var names. Used by cascade execution paths
    to apply per-cascade key configuration from cascade.json.

    @since 0.122.0 api_key_env_overrides parameter added *)
val parse_model_strings :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  string list -> Llm_provider.Provider_config.t list

(** {1 JSON Config Loading} *)

(** Load a named model list from a JSON config file.

    The JSON file maps "{name}_models" keys to string arrays:
    {[
      { "primary_models":    ["llama:qwen3.5", "glm:auto"],
        "evaluation_models": ["llama:qwen3.5", "glm:glm-4.5"] }
    ]}

    Results are cached and hot-reloaded when the file mtime changes.
    Returns an empty list when the file is missing or the key is absent
    (caller provides defaults). *)
val load_profile :
  config_path:string ->
  name:string ->
  string list

(** How a cascade name was resolved. *)
type cascade_source =
  | Named              (** Found as "{name}_models" in config *)
  | Default_fallback   (** Name not found; used "default_models" *)
  | Hardcoded_defaults (** Neither found; used hardcoded [defaults] *)

(** Resolve model strings for a named cascade.

    Resolution order:
    1. Named profile "{name}_models" from [config_path]
    2. "default_models" profile from [config_path] (fallback)
    3. Hardcoded [defaults]

    When [config_path] is [None], returns [defaults] directly. *)
val resolve_model_strings :
  ?config_path:string ->
  name:string ->
  defaults:string list ->
  unit ->
  string list

(** Expand execution-time convenience fallbacks while preserving stable order.

    Uses the same provider:auto expansion as {!expand_auto_models}, so
    CLI and GLM family entries execute in the same concrete order the
    dashboard shows by default.

    When [rotation_scope] is provided, each [provider:auto] entry is
    rotated independently within that scope so repeated execution calls
    do not always start from the same concrete model.

    Duplicate entries are removed after expansion, keeping the first
    appearance. This lets callers keep config concise while still
    getting automatic provider-internal failover at execution time.

    @since 0.116.2 *)
val expand_model_strings_for_execution :
  ?rotation_scope:string ->
  string list ->
  string list

(** Like {!resolve_model_strings} but also returns which resolution
    path was taken. Use this to detect typos: if [source <> Named]
    when you expected a named profile, the cascade name is likely wrong.

    @since 0.78.0 *)
val resolve_model_strings_traced :
  ?config_path:string ->
  name:string ->
  defaults:string list ->
  unit ->
  string list * cascade_source

(** Per-candidate info in a weighted selection decision.

    Captures the state that influenced a single candidate's ordering
    at decision time: its declared weight, health-adjusted effective
    weight, and current health signals.

    @since 0.139.0 *)
type candidate_info = {
  model_string : string;        (** "provider:model_id" as written in config *)
  display_model_string : string; (** User-facing label for the configured candidate *)
  provider_name : string option; (** Raw provider prefix when present *)
  display_provider_name : string option; (** User-facing provider family label *)
  runtime_kind : string option; (** "local" / "cli_agent" / "direct_api" when known *)
  expanded_models : string list; (** Concrete execution order for this configured candidate *)
  config_weight : int;          (** Weight from [cascade.json] ([1] when absent) *)
  effective_weight : int;       (** Weight after health adjustment; [0] = cooled-down *)
  success_rate : float;         (** Rolling-window success rate, [0.0]–[1.0] *)
  in_cooldown : bool;           (** Provider currently skipped by cooldown *)
}

(** Full trace of a cascade selection decision.

    Consumers can use this to surface, in dashboards/telemetry,
    why a particular provider was attempted first and what signals
    were considered.

    [candidates] is in final attempt order — the first entry is the
    provider the cascade will try first.

    When the profile has no weights (every entry is [weight=1]), no
    probabilistic shuffle happens and [effective_weight = config_weight = 1]
    for each entry.

    @since 0.139.0 *)
type selection_trace = {
  candidates : candidate_info list;
  source : cascade_source;
}

(** Build a live selection trace from already-known weighted entries.

    Applies {!order_weighted_entries} and snapshots current health signals
    without rereading raw [cascade.json]. Useful when callers already hold
    validated runtime profile data and need the same dashboard trace shape.

    @since 0.150.4 *)
val selection_trace_of_weighted_entries :
  ?source:cascade_source ->
  Cascade_config_loader.weighted_entry list ->
  selection_trace

(** Like {!resolve_model_strings_traced} but also returns per-candidate
    health signals that influenced the ordering. Useful for rendering
    the cascade decision in dashboards without re-deriving state.

    Non-breaking: callers who only need the ordered model list can
    continue using {!resolve_model_strings} or {!resolve_model_strings_traced}.

    @since 0.139.0 *)
val resolve_model_strings_with_trace :
  ?config_path:string ->
  name:string ->
  defaults:string list ->
  unit ->
  string list * selection_trace

(** {1 Raw JSON Access} *)

(** Load and cache the raw JSON config file.
    Cached with mtime-based hot-reload.
    Exposed for consumers needing custom fields beyond model lists
    (e.g., per-cascade temperature/max_tokens overrides).

    @since 0.89.1 *)
val load_json : string -> (Yojson.Safe.t, string) result

(** {1 Inference Parameters} *)

(** Per-cascade inference parameter overrides. *)
type inference_params = {
  temperature: float option;
  max_tokens: int option;
}

(** Resolve inference parameters from cascade.json.

    Resolution order:
    1. ["{name}_temperature"] / ["{name}_max_tokens"]
    2. ["default_temperature"] / ["default_max_tokens"]
    3. [None] (caller uses own defaults)

    @since 0.89.1 *)
val resolve_inference_params :
  config_path:string -> name:string -> inference_params

(** Resolve per-cascade API key env var overrides from cascade.json.

    Supports two formats:
    - String: applies to all providers.
      [{"{name}_api_key_env": "ZAI_API_KEY_SB"}]
    - Object: per-provider mapping.
      [{"{name}_api_key_env": {"glm": "ZAI_API_KEY_SB", "glm-coding": "ZAI_API_KEY_SB"}}]

    Falls back to ["default_api_key_env"], then empty list (use registry defaults).

    @since 0.122.0 *)
val resolve_api_key_env :
  config_path:string -> name:string -> (string * string) list

(** {1 Discovery-Aware Health Filtering} *)

(** Filter a provider list by local endpoint health.

    Probes local (llama-server) endpoints via {!Discovery}. When all
    local endpoints are unhealthy, removes local providers from the list
    so cloud providers serve as fallback.

    When the list contains only local providers, passes through unchanged
    (let the provider return a connection error rather than an empty list).

    Cloud providers always pass through unfiltered. *)
val filter_healthy :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  Llm_provider.Provider_config.t list ->
  Llm_provider.Provider_config.t list

(** {1 Context Window Resolution} *)

(** Effective max context tokens for a provider entry.

    Returns [caps.max_context_tokens] when known (per-model), otherwise
    falls back to [entry.max_context] (per-provider default from the registry).

    @since 0.78.0 *)
val effective_max_context :
  Llm_provider.Provider_registry.entry -> Llm_provider.Capabilities.capabilities -> int

(** Resolve a model label to the per-slot context of the endpoint
    that would serve it.

    Uses the same resolution path as [make_registry_config]:
    - ["llama:*"] → peeks at current round-robin endpoint (no advance)
    - ["custom:model@url"] → looks up the parsed URL
    - Cloud providers → [None] (use static {!effective_max_context} instead)

    This is the SSOT for "how much context does this label have?"
    Consumers should call this instead of guessing from endpoint lists.

    @since 0.100.8 *)
val resolve_label_context : string -> int option

(** {1 Capability-Aware Filtering} *)

(** Filter providers by a capability predicate.

    Resolves capabilities per-model (via {!Llm_provider.Capabilities.for_model_id})
    with registry-level fallback. Removes providers that do not satisfy
    [pred]. If all providers would be removed, returns the original list
    unchanged (let the provider return an API error).

    Example: filter to providers supporting tools:
    {[ filter_by_capabilities ~pred:(fun c -> c.supports_tools) providers ]}

    @since 0.78.0 *)
val filter_by_capabilities :
  pred:(Llm_provider.Capabilities.capabilities -> bool) ->
  Llm_provider.Provider_config.t list ->
  Llm_provider.Provider_config.t list

(** {1 Helpers for Cascade Consumers} *)

(** Extract the concatenated text content from an API response.
    Joins all {!Llm_provider.Types.Text} blocks. Useful for accept validators. *)
val text_of_response : Llm_provider.Types.api_response -> string

val apply_provider_filter :
  provider_filter:string list option ->
  label:string ->
  Llm_provider.Provider_config.t list ->
  Llm_provider.Provider_config.t list

(** {1 Local Capacity Query} *)

(** Point-in-time capacity for local LLM endpoints.
    All [process_*] counts reflect this OAS process only —
    other clients sharing the same server are not visible.
    @since 0.97.0 *)
type local_capacity = {
  total : int;
  (** Server slot count from discovery. *)
  process_active : int;
  (** Slots held by this process. *)
  process_available : int;
  (** [total - process_active]. May overestimate if other consumers exist. *)
  process_queue_length : int;
  (** Fibers waiting for a slot in this process. *)
  all_discovered : bool;
  (** [true] only when every contributing endpoint has [Discovered] source.
      When [false], slot count may be a guessed default. *)
  endpoints_found : int;
  (** Number of local endpoints found. 0 means cloud-only selection. *)
}

val local_capacity_for_selections :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?config_path:string ->
  string list ->
  local_capacity
(** Query local endpoint capacity for cascade selection strings.

    Each selection string is resolved through the same path as
    [complete_named]: named profile lookup, then model string parsing.
    Only local endpoints are considered; cloud providers are ignored.

    Probes endpoints not yet in the throttle table via {!Discovery}
    (~10ms on localhost), populating the table as a side-effect.
    Returns [endpoints_found = 0] for cloud-only selections.

    @since 0.97.0 *)

(** {1 Pluggable strategy resolution}

    @since 0.9.6 *)

val resolve_strategy :
  ?config_path:string ->
  name:string ->
  unit ->
  Cascade_strategy.t
(** [resolve_strategy ~config_path ~name] reads
    [{name}_strategy], [{name}_max_cycles], [{name}_backoff_base_ms],
    [{name}_backoff_cap_ms] from [config_path] and returns the
    corresponding {!Cascade_strategy.t}.

    Behaviour when fields are absent or [config_path] is [None]:
    - returns {!Cascade_strategy.failover} (linear failover, single
      cycle, default backoff).  This guarantees bit-identical
      behaviour to cascade calls that have no strategy
      configuration.

    Behaviour on parse error:
    - unknown [strategy] value → emits a one-time stderr warning and
      falls back to [Failover].  Keeper startup is not blocked by
      config typos.
    - non-positive [max_cycles] → clamped to 1.
    - non-positive [backoff_base_ms] → clamped to 1.
    - [backoff_cap_ms < backoff_base_ms] → clamped up to
      [backoff_base_ms]. *)

val normalize_priority_tiers :
  config_path:string ->
  name:string ->
  string list list ->
  (string list list, string) result
(** Validate and normalize a [priority_tier] tier matrix against the
    configured candidate model ids for [name]. Returns [Error] when all
    tiers collapse or when the profile has no configured candidates. *)

val resolve_ollama_max_concurrent :
  ?config_path:string ->
  name:string ->
  unit ->
  int option
(** Per-cascade override for the ollama client-capacity registration
    default ({!Cascade_client_capacity.auto_register_for_candidates}).
    [None] means "use the env-var default
    ([MASC_OLLAMA_MAX_CONCURRENT] or 1)". *)

val resolve_cli_max_concurrent :
  ?config_path:string ->
  name:string ->
  unit ->
  int option
(** Per-cascade override for the CLI client-capacity registration
    default ({!Cascade_client_capacity.auto_register_cli_for_candidates}).
    [None] means "use the env-var default
    ([MASC_CLI_MAX_CONCURRENT] or 1)".
    @since 0.9.8 *)

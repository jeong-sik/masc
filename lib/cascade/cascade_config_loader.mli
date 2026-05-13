(** Cascade catalog source loading with mtime-based hot-reload.

    @since 0.59.0
    @since 0.92.0 extracted from Cascade_config

    @stability Internal
    @since 0.93.1 *)

(** Load and cache the cascade catalog source.

    Despite returning [Yojson.Safe.t] for backward compatibility with the
    JSON-shaped consumers (which still walk the value via
    [Yojson.Safe.Util]), this function does not read any JSON from disk.
    The on-disk source is [cascade.toml]; it is parsed by [Otoml] and
    rendered to an in-memory [Yojson.Safe.t] view by
    [Cascade_toml_materializer]. The cache is keyed by the resolved
    source-path mtime.

    @since RFC-0058 §9 Phase 9.3 renamed from [load_json] — no on-disk
    JSON is read or written. *)
val load_catalog_source : string -> (Yojson.Safe.t, string) result

(** Same as {!load_catalog_source}, but suppresses TOML source-read
    trace / race telemetry for high-frequency diagnostic polling. *)
val load_catalog_source_for_diagnostics : string -> (Yojson.Safe.t, string) result

(** Drop the cached entry for one cascade source path.

    Intended for in-process editors/tests that overwrite the file and need
    the next read to bypass the previous mtime cache entry immediately.

    @since 0.160.1 *)
val invalidate_cache_entry : string -> unit

(** A model entry with an optional weight for weighted cascade selection.
    Weight defaults to 1 when not specified.
    @since 0.137.0
    @since 0.150.0 [supports_tool_choice] field added
    @since RFC-0027 PR-9a [secondary] dual-track field added *)
type weighted_entry = {
  model: string;
  weight: int;
  supports_tool_choice: bool option;
  (** Per-entry capability override forwarded to
      [Llm_provider.Provider_config.supports_tool_choice_override].
      [None] = use registry default; [Some b] = force [b]. Consumers
      declare verified model-side tool_choice support per cascade entry
      (e.g. Qwen3.5 w/ native Jinja chat template) without the SDK
      pattern-matching on [model_id]. *)
  secondary: string option;
  (** Optional dual-track fallback model for this entry (RFC-0027 PR-9).
      When set, the resolver should use [model] as the primary attempt
      and fall back to [secondary] when [model]'s provider rejects the
      turn at the capability gate (e.g. CLI runtime missing per-request
      MCP HTTP headers).  Idiomatic pairing: CLI runtime primary +
      direct-API secondary, e.g.
      [{ model = "gemini_cli:auto"; secondary = Some "gemini-api:gemini-3-flash" }].
      [None] = single-track entry.

      Unknown / invalid provider schemes in [secondary] are surfaced by
      the resolver as normal provider-not-found errors when fallback
      fires. *)
  secondary_supports_tool_choice: bool option;
  (** Per-entry capability override for [secondary], analogous to
      [supports_tool_choice].  [None] when [secondary] is [None] or
      when no explicit override is declared. *)
}

(** Deprecated logical route keys must not be treated as concrete catalog
    profiles. *)
val is_deprecated_logical_profile_name : string -> bool

(** Per-cascade inference parameter overrides. *)
type inference_params = {
  temperature: float option;
  max_tokens: int option;
  keep_alive: string option;
  (** Ollama [keep_alive] override: integer seconds or duration string.
      Honored only when the resolved provider is Ollama. *)
  num_ctx: int option;
  (** Ollama [num_ctx] override: per-request KV cache allocation in
      tokens. Honored only when the resolved provider is Ollama. *)
  thinking_enabled: bool option;
  thinking_budget: int option;
  (** [thinking_budget] is a per-turn thinking token budget seed.
      Keeper adaptive logic may adjust this per turn based on intent
      classification and error/retry signals.  Provider-specific
      mapping happens downstream in OAS. *)
}

(** Resolve inference parameters from the in-memory cascade view.

    Resolution order:
    1. ["{name}_temperature"] / ["{name}_max_tokens"] /
       ["{name}_keep_alive"] / ["{name}_num_ctx"] /
       ["{name}_thinking_enabled"] / ["{name}_thinking_budget"]
    2. ["default_temperature"] / ["default_max_tokens"] /
       ["default_keep_alive"] / ["default_num_ctx"] /
       ["default_thinking_enabled"] / ["default_thinking_budget"]
    3. [None] (caller uses own defaults) *)
val resolve_inference_params :
  config_path:string -> name:string -> inference_params

(** Resolve per-cascade API key env var overrides from the in-memory cascade view.

    Resolution order:
    1. ["{name}_api_key_env"] from [config_path]
    2. ["default_api_key_env"] from [config_path]
    3. Empty list (use provider registry defaults)

    The JSON value can be a string (applies to all providers via ["*"] key)
    or an object mapping provider names to env var names.

    @since 0.122.0 *)
val resolve_api_key_env :
  config_path:string -> name:string -> (string * string) list

(** Per-cascade pluggable-strategy override.

    All fields are optional.  Absent fields fall through to
    {!Cascade_strategy.default_cycle_policy} or to the [Failover]
    kind.  The loader returns the raw values; the caller (typically
    [Cascade_config.resolve_strategy]) is responsible for parsing the
    [kind] string and warn-and-fallback on unknown values.

    @since 0.9.6 *)
type strategy_config = {
  kind : string option;
  (** ["{name}_strategy"]. Recognized values: ["failover"],
      ["capacity_aware"], ["weighted_random"],
      ["circuit_breaker_cycling"]. *)

  max_cycles : int option;
  (** ["{name}_max_cycles"]. Defaults to 1. *)

  backoff_base_ms : int option;
  (** ["{name}_backoff_base_ms"]. Defaults to 500. *)

  backoff_cap_ms : int option;
  (** ["{name}_backoff_cap_ms"]. Defaults to 10_000. *)

  ollama_max_concurrent : int option;
  (** ["{name}_ollama_max_concurrent"]. When set, overrides the
      ollama auto-registration default for any ollama-like base URL
      in this cascade's candidate list. *)

  cli_max_concurrent : int option;
  (** ["{name}_cli_max_concurrent"]. When set, overrides the CLI
      auto-registration default ([MASC_CLI_MAX_CONCURRENT] or 1)
      for every CLI provider (Claude_code / Gemini_cli / Codex_cli)
      in this cascade's candidate list.  CLI providers share a
      single concurrency cap because each CLI binary is typically
      limited to one in-flight subprocess.
      @since 0.9.8 *)

  tiers : string list list option;
  (** ["{name}_tiers"]. Used by the [priority_tier] strategy.  Each
      inner array is a tier of provider keys (matched against the
      [model] field in [{name}_models]); outer order is tier order
      (tier 0 = highest priority).  Example JSON:
      [\[\["ollama:qwen3-coder:30b"\], \["gemini_cli:gemini-3-flash-preview"\]\]].
      @since 0.9.7 *)

  sticky_ttl_ms : int option;
  (** ["{name}_sticky_ttl_ms"]. Used by the [sticky] strategy.
      Defaults to {!Cascade_strategy.default_sticky_ttl_ms}
      ([300_000]) when [kind] is [sticky] and this field is absent.
      Values [<= 0] disable affinity entirely.
      @since 0.9.7 *)

  (* ── Scoring parameter overrides (Weighted_random strategy) ── *)

  latency_baseline_ms : float option;
  (** ["{name}_latency_baseline_ms"]. Provider p50 above this value
      incurs a fractional score penalty.  Falls back to env var
      [MASC_CASCADE_LATENCY_BASELINE_MS] or default 2000.0 when absent. *)

  rate_limit_recency_window_s : float option;
  (** ["{name}_rate_limit_recency_window_s"]. Lookback window for
      counting recent 429 events.  Falls back to env var or default
      60.0. *)

  rate_limit_decay_base : float option;
  (** ["{name}_rate_limit_decay_base"]. Per-event decay multiplier
      in (0.0, 1.0).  Falls back to env var or default 0.5. *)

  rate_limit_skip_after : int option;
  (** ["{name}_rate_limit_skip_after"]. Hard-skip threshold for 429
      events.  Falls back to env var or default 3. *)

  server_error_recency_window_s : float option;
  (** ["{name}_server_error_recency_window_s"]. Lookback window for
      counting recent 5xx events.  Falls back to env var or default
      120.0. *)

  server_error_decay_base : float option;
  (** ["{name}_server_error_decay_base"]. Per-event decay multiplier
      in (0.0, 1.0).  Falls back to env var or default 0.6. *)

  server_error_skip_after : int option;
  (** ["{name}_server_error_skip_after"]. Hard-skip threshold for 5xx
      events.  Falls back to env var or default 4. *)
}

val resolve_strategy_config :
  config_path:string -> name:string -> strategy_config

val resolve_strategy_config_for_diagnostics :
  config_path:string -> name:string -> strategy_config

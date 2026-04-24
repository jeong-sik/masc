(** JSON config loading with mtime-based hot-reload.

    @since 0.59.0
    @since 0.92.0 extracted from Cascade_config

    @stability Internal
    @since 0.93.1 *)

(** Load and cache a raw JSON config file.
    Cached with mtime-based hot-reload. When a sibling [cascade.toml] exists,
    it is validated/materialized first and this loader then reads the
    generated [cascade.json]. *)
val load_json : string -> (Yojson.Safe.t, string) result

(** Drop the cached JSON entry for one [cascade.json] path.

    Intended for in-process editors/tests that overwrite the file and need
    the next read to bypass the previous mtime cache entry immediately.

    @since 0.160.1 *)
val invalidate_cache_entry : string -> unit

(** A model entry with an optional weight for weighted cascade selection.
    Weight defaults to 1 when not specified.
    @since 0.137.0
    @since 0.150.0 [supports_tool_choice] field added *)
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
}

(** Catalog metadata for one named cascade profile discovered from
    [cascade.json].

    A profile enters the catalog when it declares at least one
    recognized cascade schema key such as ["{name}_models"],
    ["{name}_temperature"], ["{name}_strategy"], etc. This keeps
    profile discovery aligned with the loader's typed schema instead of
    duplicating ad-hoc JSON-key parsing at call sites. *)
type catalog_entry = {
  name : string;
  keeper_assignable : bool;
  (** Whether the profile may be assigned to keepers. Defaults to [true]
      when ["{name}_keeper_assignable"] is absent. *)
}

(** Load the cascade catalog from [config_path].

    Discovery is schema-driven: a profile is included when the JSON
    contains at least one recognized per-cascade key for that [name].
    The optional metadata key ["{name}_keeper_assignable"] marks
    system-only profiles that should remain editable/visible but must
    not appear in keeper-assignment UIs.

    Returns [Error _] when the file cannot be read or parsed. *)
val load_catalog :
  config_path:string ->
  (catalog_entry list, string) result

(** Load a named model list from a JSON config file.

    The JSON file maps ["{name}_models"] keys to string arrays.
    Results are cached and hot-reloaded when the file mtime changes.
    Returns an empty list when the file is missing or the key is absent. *)
val load_profile :
  config_path:string ->
  name:string ->
  string list

(** Like {!load_profile} but preserves weight information.

    Supports two JSON formats in the model array:
    - Plain strings: [{"model": s, "weight": 1}]
    - Objects: [{"model": "provider:id", "weight": 50}]

    When all weights are 1, the caller should treat the list as unweighted
    (preserving backward-compatible fixed ordering).

    @since 0.137.0 *)
val load_profile_weighted :
  config_path:string ->
  name:string ->
  weighted_entry list

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
}

(** Resolve inference parameters from cascade.json.

    Resolution order:
    1. ["{name}_temperature"] / ["{name}_max_tokens"] /
       ["{name}_keep_alive"] / ["{name}_num_ctx"]
    2. ["default_temperature"] / ["default_max_tokens"] /
       ["default_keep_alive"] / ["default_num_ctx"]
    3. [None] (caller uses own defaults) *)
val resolve_inference_params :
  config_path:string -> name:string -> inference_params

(** Resolve per-cascade API key env var overrides from cascade.json.

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
      [\[\["ollama:qwen3-coder:30b"\], \["gemini_cli:gemini-2.5-flash"\]\]].
      @since 0.9.7 *)

  sticky_ttl_ms : int option;
  (** ["{name}_sticky_ttl_ms"]. Used by the [sticky] strategy.
      Defaults to {!Cascade_strategy.default_sticky_ttl_ms}
      ([300_000]) when [kind] is [sticky] and this field is absent.
      Values [<= 0] disable affinity entirely.
      @since 0.9.7 *)
}

val resolve_strategy_config :
  config_path:string -> name:string -> strategy_config

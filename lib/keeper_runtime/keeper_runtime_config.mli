(** Keeper_runtime_config — load startup runtime env seeding from
    [<resolved config root>/runtime.toml].

    Per-base-path config for transport liveness, capacity, WebSearch
    provider selection, and other startup-scoped runtime parameters that
    previously lived only in environment variables. Closes the architectural gap
    where tools/personas/runtime are per-base-path but selected runtime tuning
    was global.

    Precedence (highest first):
      1. Process env var (caller override, e.g. CI/test)
      2. TOML value from [<resolved config root>/runtime.toml]
      3. Hardcoded default in the owning [Env_config_*] reader.

    The TOML loader runs at server startup, before any module that reads
    these env vars initializes. It stores boot defaults in a process-local
    override table so existing config readers can resolve TOML-backed values
    without mutating the parent environment. This file is startup-only today;
    there is no hot-reload path.

    @since 0.7.1 *)

(** Load TOML from [<resolved config root>/runtime.toml] and
    record any overrides in the process-local boot override store.

    The resolved config root honors [MASC_CONFIG_DIR] when set; otherwise it
    uses [<base_path>/.masc/config].

    Process-level env vars set by the caller take precedence — the TOML
    value is only applied when the env var is unset. This preserves the
    CI/test workflow of overriding via env.

    Returns [Ok num_overrides] (count of TOML keys actually applied,
    excluding those preempted by existing env vars), or [Error msg] on
    parse failure.  Missing file is not an error: returns [Ok 0]. *)
val load_and_apply : base_path:string -> (int, string) result

(** Read the raw TOML value for [env_name] from the shadow registry.
    Returns [None] when the key was absent from [runtime.toml]
    or the file did not exist.

    This is the TOML intent *independent* of any env override — it lets
    operator surfaces warn when an env var silently differs from the
    operator's TOML configuration (issue #17192). *)
val toml_value_opt : string -> string option

(** Pure resolution: parse TOML and determine which env vars would be
    overridden, without mutating the process-local boot override store.

    [~env_lookup] defaults to [Env_config_core.raw_value_opt]; tests inject a fake env
    to avoid global process env dependency.

    Returns [(count, overrides)] where [overrides] is
    [(env_name, value) list]. *)
val resolve_overrides :
  ?env_lookup:(string -> string option) ->
  Keeper_toml_loader.toml_doc ->
  int * (string * string) list

(** TOML schema (for documentation):

    {[
      [autonomous]
      concurrency                 = 3

      [reactive]
      concurrency                 = 4

      [heartbeat]
      sleep_chunk_sec             = 1.5
      board_wakeup_max            = 4

      [turn]
      # stream_idle_timeout_sec is intentionally omitted (disabled).
      [web_search]
      searxng_url                 = "http://localhost:8888"
      provider                    = "auto"
    ]}

    Unknown keys are ignored (forward compatibility). *)

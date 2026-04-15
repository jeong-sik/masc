(** Keeper_runtime_config — load startup keeper env seeding from
    [<base_path>/.masc/config/keeper_runtime.toml].

    Per-base-path config for keeper turn budgets, semaphore timeouts, and
    other runtime parameters that previously lived only in environment
    variables.  Closes the architectural gap where tools/personas/cascade
    are per-base-path but keeper runtime tuning was global.

    Precedence (highest first):
      1. Process env var (caller override, e.g. CI/test)
      2. TOML value from [<base_path>/.masc/config/keeper_runtime.toml]
      3. Hardcoded default in [Env_config_keeper.KeeperKeepalive].

    The TOML loader runs at server startup, before any module that reads
    these env vars initializes. It stores boot defaults in a process-local
    override table so existing config readers can resolve TOML-backed values
    without mutating the parent environment. This file is startup-only today;
    there is no hot-reload path.

    @since 0.7.1 *)

(** Load TOML from [<base_path>/.masc/config/keeper_runtime.toml] and
    record any overrides in the process-local boot override store.

    Process-level env vars set by the caller take precedence — the TOML
    value is only applied when the env var is unset. This preserves the
    CI/test workflow of overriding via env.

    Returns [Ok num_overrides] (count of TOML keys actually applied,
    excluding those preempted by existing env vars), or [Error msg] on
    parse failure.  Missing file is not an error: returns [Ok 0]. *)
val load_and_apply : base_path:string -> (int, string) result

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
      max_turns_per_call          = 7
      semaphore_wait_timeout_sec  = 150

      [reactive]
      max_turns_per_call          = 15
    ]}

    Unknown keys are ignored (forward compatibility). *)

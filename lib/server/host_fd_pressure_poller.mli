(** Host_fd_pressure_poller — bridges out-of-process host FD pressure
    signal into [Keeper_fd_pressure.engage_external]. (RFC-0137 PR-2)

    The companion [scripts/monitor-system-health.sh] daemon atomically
    writes the configured state file (JSON one-line) on WARN/CRIT
    thresholds against [kern.maxfiles]; file absence means OK.
    [MASC_HOST_FD_PRESSURE_STATE_FILE] is the canonical path override.
    [MASC_SYSMON_PRESSURE_STATE] remains a producer-side compatibility
    fallback when the canonical override is absent.

    This module starts a single Eio fiber that stats the state file
    every 1s. On parse success + advancing [ts] it invokes
    [Keeper_fd_pressure.engage_external] with the matching level.

    Concurrency: idempotent. [Keeper_fd_pressure.engage_external] is
    monotonic on its own [cooldown_until] CAS, so stale or duplicate
    reads are absorbed there — no separate dedup atomic is needed.

    Failure modes: malformed JSON, partial writes, missing file,
    stat(2) errors — all no-ops. Single throttled WARN log per hour. *)

type state_file_source =
  | Canonical_env
  | Legacy_sysmon_env
  | Default

type state_file_resolution =
  { path : string
  ; source : state_file_source
  ; ignored_legacy_path : string option
  }

val resolve_state_file_path :
  getenv:(string -> string option) -> state_file_resolution
(** Resolve the state-file path from environment lookup [getenv].
    [MASC_HOST_FD_PRESSURE_STATE_FILE] is authoritative. The legacy
    producer-side [MASC_SYSMON_PRESSURE_STATE] is used only when the
    canonical env is absent. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
(** [start ~sw ~clock] forks the poller fiber under [sw]. Wired from
    [Server_bootstrap_loops.start_background_maintenance]. Cancelled
    when [sw] terminates. *)

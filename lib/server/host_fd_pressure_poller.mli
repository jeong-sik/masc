(** Host_fd_pressure_poller — bridges out-of-process host FD pressure
    signal into [Keeper_fd_pressure.engage_external]. (RFC-0137 PR-2)

    The companion [sysmon-fd-oom-disk.sh] daemon atomically writes
    [/tmp/masc-host-pressure.state] (JSON one-line) on WARN/CRIT
    thresholds against [kern.maxfiles]; file absence means OK.

    This module starts a single Eio fiber that stats the state file
    every 1s. On parse success + advancing [ts] it invokes
    [Keeper_fd_pressure.engage_external] with the matching level.

    Concurrency: idempotent. [Keeper_fd_pressure.engage_external] is
    monotonic on its own [cooldown_until] CAS, so stale or duplicate
    reads are absorbed there — no separate dedup atomic is needed.

    Failure modes: malformed JSON, partial writes, missing file,
    stat(2) errors — all no-ops. Single throttled WARN log per hour. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
(** [start ~sw ~clock] forks the poller fiber under [sw]. Wired from
    [Server_bootstrap_loops.start_background_maintenance]. Cancelled
    when [sw] terminates. *)

val state_file_path : unit -> string
(** [state_file_path ()] returns the configured pressure state path.
    Default [/tmp/masc-host-pressure.state]; env-overrideable via
    [MASC_HOST_FD_PRESSURE_STATE_FILE]. Exposed for testing. *)

val poll_interval_sec : unit -> float
(** [poll_interval_sec ()] returns the poll cadence. Default 1.0s;
    env-overrideable via [MASC_HOST_FD_PRESSURE_POLL_INTERVAL_SEC],
    bounded [0.5, 60.0]. *)

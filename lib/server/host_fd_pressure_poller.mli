(** Host_fd_pressure_poller — bridges out-of-process host FD pressure
    signal into [Keeper_fd_pressure.engage_external]. (RFC-0137 PR-2)

    The companion [scripts/monitor-system-health.sh] daemon atomically
    writes the configured state file (JSON one-line) on WARN/CRIT
    thresholds against [kern.maxfiles]; file absence means OK.
    [MASC_HOST_FD_PRESSURE_STATE_FILE] is the canonical path override.
    [MASC_SYSMON_PRESSURE_STATE] remains a compatibility fallback when the
    canonical env is absent.

    This module starts a single Eio fiber that reads the state file
    every 1s. On parse success + advancing [ts] it invokes
    [Keeper_fd_pressure.engage_external] with the matching level.

    Concurrency: idempotent. [Keeper_fd_pressure.engage_external] is
    monotonic on its own [cooldown_until] CAS, so stale or duplicate
    reads are absorbed there — no separate dedup atomic is needed.

    Failure modes: malformed JSON, partial writes, missing file,
    stat(2) errors — all no-ops. Single throttled WARN log per hour. *)

type state_file_source =
  | Canonical_env
  | Legacy_env
  | Default

type state_file_resolution =
  { path : string
  ; source : state_file_source
  }

type parsed =
  { level : Keeper_fd_pressure.external_level
  ; ts : float
  ; reason : string
  }

type state_line_parse_error =
  | State_line_json_parse_error of string
  | State_line_expected_object of { received : string }
  | State_line_missing_or_invalid_field of
      { field : string
      ; received : string option
      }
  | State_line_unknown_level of string
  | State_line_invalid_timestamp of string

val state_line_parse_error_to_string : state_line_parse_error -> string

val resolve_state_file_path : base_path:string -> unit -> state_file_resolution
(** Resolve the state-file path. Explicit env overrides win; otherwise the
    default state file lives under [<base_path>/.masc]. *)

val state_file_env_conflict : unit -> (string * string) option
(** [Some (canonical, legacy)] when both env vars are set to different paths. *)

val parse_state_line_result : string -> (parsed, state_line_parse_error) result
(** Parse one sysmon state-file line with typed failure visibility. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> base_path:string -> unit
(** [start ~sw ~clock ~base_path] forks the poller fiber under [sw]. Wired from
    [Server_bootstrap_loops.start_background_maintenance]. Cancelled
    when [sw] terminates. *)

(** MASC Coord - Core coordination hub.

    This module ties together all Coord sub-modules (utils, state, lifecycle,
    init, status, task, query, agent, portal, worktree, gc). *)

(** {1 Included sub-modules} *)

include module type of Coord_utils
include module type of Coord_state
include module type of Coord_broadcast
include module type of Coord_lifecycle
include module type of Coord_init
include module type of Coord_status
include module type of Coord_task
include module type of Coord_task_schedule
include module type of Coord_query
include module type of Coord_portal
include module type of Coord_worktree
include module type of Coord_gc

(** {1 Coord lifecycle (overrides)} *)
include module type of Coord_agent

(** Initialize MASC room with optional auto-join.
    Wraps [Coord_init.init] and calls [join] when [agent_name] is provided. *)
val init : config -> agent_name:string option -> string

(** {1 FSM drift observability (#9795)} *)

(** Canonical Prometheus metric name for task FSM drift events.
    Labels: [("variant", <drift_variant>); ("force", "true" | "false")].
    Exposed so tests and Grafana rules can pin the name. *)
val fsm_drift_metric : string

(** Increment {!fsm_drift_metric} with the supplied labels.
    Kept for tests and direct callers that don't carry agent
    attribution.  Production drift events flow through
    {!record_fsm_drift_with_agent} via
    {!Coord_hooks.fsm_drift_observer_fn}. *)
val record_fsm_drift : variant:string -> force:bool -> unit

(** Per-agent variant of {!fsm_drift_metric}. Labels:
    [("variant", _); ("agent_name", _); ("force", "true" | "false")].
    Cardinality is bounded by fleet size (~10 keepers in masc-mcp),
    so the per-agent breakout is safe for Prometheus. *)
val fsm_drift_per_agent_metric : string

(** Emit BOTH the variant-only {!fsm_drift_metric} and the
    per-agent {!fsm_drift_per_agent_metric}.  Wired to
    {!Coord_hooks.fsm_drift_observer_fn} at module load so every
    drift detected by [Coord_task.transition] surfaces with agent
    attribution.  This lets ratchet readiness ("which keepers are
    skipping Start?") be answered from Prometheus without
    log-scraping the WARN line. *)
val record_fsm_drift_with_agent
  :  variant:string
  -> force:bool
  -> agent_name:string
  -> unit

(** {1 Process timeout observability (#9632)} *)

(** Canonical Prometheus metric for [Process_eio] timeouts
    ([masc_process_timeout_total]).  Labels: [program] (argv0
    basename, e.g. ["git"], ["gh"]), [timeout_sec] (configured budget,
    e.g. ["15"], ["60"]).  Exposed so tests and Grafana rules can pin
    the name. *)
val process_timeout_metric : string

(** Increment {!process_timeout_metric}.  Wired to
    {!Process_eio.process_timeout_observer_fn} at module load so every
    [Eio.Time.Timeout] in [run_argv] / [run_argv_with_stdin] /
    [run_argv_with_stdin_and_status_split] / [run_argv_with_status_split]
    surfaces in Prometheus without taking a direct dependency on
    [masc_mcp.Prometheus] from the lower [masc_process] layer. *)
val record_process_timeout : program:string -> timeout_sec:float -> unit

(** {1 Distributed lock observability (#9645)} *)

(** Canonical Prometheus metric for distributed lock acquire
    exhaustion ([masc_distributed_lock_acquire_failed_total]).
    Labels: [key, attempts].  Exposed so tests and Grafana
    rules can pin the name. *)
val distributed_lock_acquire_failed_metric : string

(** Increment {!distributed_lock_acquire_failed_metric} with
    [(key, attempts)] labels.  Wired to
    {!Coord_hooks.distributed_lock_acquire_failed_fn} so
    [Coord_utils_ops] can fire the metric without taking a
    direct [Prometheus] dependency. *)
val record_distributed_lock_acquire_failed : key:string -> attempts:int -> unit

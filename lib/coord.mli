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
include module type of Coord_agent
(** {1 Coord lifecycle (overrides)} *)

(** Initialize MASC room with optional auto-join.
    Wraps [Coord_init.init] and calls [join] when [agent_name] is provided. *)
val init : config -> agent_name:string option -> string

(** {1 FSM drift observability (#9795)} *)

val fsm_drift_metric : string
(** Canonical Prometheus metric name for task FSM drift events.
    Labels: [("variant", <drift_variant>); ("force", "true" | "false")].
    Exposed so tests and Grafana rules can pin the name. *)

val record_fsm_drift : variant:string -> force:bool -> unit
(** Increment {!fsm_drift_metric} with the supplied labels.
    Kept for tests and direct callers that don't carry agent
    attribution.  Production drift events flow through
    {!record_fsm_drift_with_agent} via
    {!Coord_hooks.fsm_drift_observer_fn}. *)

val fsm_drift_per_agent_metric : string
(** Per-agent variant of {!fsm_drift_metric}. Labels:
    [("variant", _); ("agent_name", _); ("force", "true" | "false")].
    Cardinality is bounded by fleet size (~10 keepers in masc-mcp),
    so the per-agent breakout is safe for Prometheus. *)

val record_fsm_drift_with_agent :
  variant:string -> force:bool -> agent_name:string -> unit
(** Emit BOTH the variant-only {!fsm_drift_metric} and the
    per-agent {!fsm_drift_per_agent_metric}.  Wired to
    {!Coord_hooks.fsm_drift_observer_fn} at module load so every
    drift detected by [Coord_task.transition] surfaces with agent
    attribution.  This lets ratchet readiness ("which keepers are
    skipping Start?") be answered from Prometheus without
    log-scraping the WARN line. *)

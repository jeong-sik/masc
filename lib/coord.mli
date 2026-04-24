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
    Wired to {!Coord_hooks.fsm_drift_observer_fn} at module load
    so [Coord_task.transition] signals every detected drift
    through this path without [masc_coord] needing a direct
    [Prometheus] dependency. *)

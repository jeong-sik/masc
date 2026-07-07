(** Runtime_observation_query_operation — closed sum for the [operation] label on
    [metric_keeper_observation_query_failures].

    Replaces 5 hardcoded literals in [keeper_world_observation.ml].
    Each value names a distinct read-path failure mode of the
    world-observation query layer. *)

type t =
  | Read_backlog_counts
  | Read_current_task (** [meta.current_task_id] → backlog record resolve failure (RFC-0314). *)
  | Count_running_keeper_fibers
  | Cursor_stale
  | Board_events
  | Scheduled_automation
  | Empty_run_reasons
  | Reconcile_read_meta (** Supervisor reconcile-loop meta read failure (#14828 sweep). *)

val to_label : t -> string

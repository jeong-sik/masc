(** Observation_query_operation — closed sum for the [operation] label on
    [metric_keeper_observation_query_failures].

    Replaces 5 hardcoded literals in [keeper_world_observation.ml].
    Each value names a distinct read-path failure mode of the
    world-observation query layer. *)

type t =
  | Read_backlog_counts
  | Count_active_agents
  | Cursor_stale
  | Board_events
  | Empty_run_reasons

val to_label : t -> string

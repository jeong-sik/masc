(** Dashboard_goals_types — re-exports the four goal-tree layers in
    dependency order: accessor, health, timeline, builder. See
    dashboard_goals_types.mli. *)

include Dashboard_goals_types_accessor
include Dashboard_goals_types_health
include Dashboard_goals_types_timeline
include Dashboard_goals_types_builder

(** Dashboard_goals_types — the node types and pure helpers of the goal-tree
    projection. The four layers below keep their own interfaces and this
    module re-exports them in this order. State-touching forest construction
    stays in Dashboard_goals, which includes this module. *)

include module type of struct include Dashboard_goals_types_accessor end
include module type of struct include Dashboard_goals_types_health end
include module type of struct include Dashboard_goals_types_timeline end
include module type of struct include Dashboard_goals_types_builder end

(** Dashboard_goals_types — pure types + task helpers extracted from
    Dashboard_goals (1998 LoC godfile).

    Holds the goal-tree node record + companion projection types + the
    pure task-status helpers used by the goal-tree builder. State-touching
    forest construction stays in Dashboard_goals. Re-included by it so
    existing callers continue to use [Dashboard_goals.tree_node] etc.
    unchanged.

    {b SSOT}: this facade re-exports the five submodule surfaces via
    [include module type of].  Each type and [val] has exactly one
    canonical definition — in the submodule that owns it.  Do not
    redeclare signatures manually here; add them to the owning
    submodule instead. *)

include module type of Dashboard_goals_types_accessor

include module type of Dashboard_goals_types_attainment

include module type of Dashboard_goals_types_health

include module type of Dashboard_goals_types_timeline

include module type of Dashboard_goals_types_builder

(** Dashboard_goals_types — pure types + task helpers extracted from
    Dashboard_goals (1998 LoC godfile).

    Holds the goal-tree node record + companion projection types + the
    pure task-status helpers used by the goal-tree builder. State-touching
    forest construction stays in Dashboard_goals. Re-included by it so
    existing callers continue to use [Dashboard_goals.tree_node] etc.
    unchanged. *)

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : (Masc_domain.task * string) list;
  convergence : float;
  health : string;
  badges : string list;
  last_activity_at : string;
  stagnation_seconds : int;
  linked_keeper_names : string list;
  pending_approval_count : int;
  infra_risk_count : int;
  linkage_source : string;
  linkage_warning_count : int;
  status_reason : string;
  blocking_source : string;
  blocking_reason : string;
  latest_keeper_ref : string option;
  latest_turn_ref : int option;
  stalled_since : string option;
  activity_observation : string;
  stagnation_status : string;
}
(** Per-goal projection node returned by [build_forest]. *)

type goal_detail_keeper = {
  meta : Keeper_types.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

type attainment_unit =
  | Percent
  | Count
  | Unknown

(** {1 Pure task-status helpers} *)

val task_is_linked_to_goal : Masc_domain.task -> string -> bool
val task_linkage_source_opt : Masc_domain.task -> string -> string option
val task_assignee : Masc_domain.task -> string option
val task_status_label : Masc_domain.task -> string
val task_is_terminal : Masc_domain.task -> bool
val task_is_done : Masc_domain.task -> bool
val task_updated_at : Masc_domain.task -> string

(** {1 Pure list utilities} *)

val dedupe_sort : string list -> string list
val link_source_of_values : string list -> string

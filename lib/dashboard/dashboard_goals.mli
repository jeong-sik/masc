(** Dashboard_goals — operator goals dashboard surface:
    forest assembly, per-node JSON rendering, full tree
    JSON envelope, and per-goal detail.

    External surface (4 entries + 1 record):
    - {b tree node record} ({!tree_node}) returned by
      {!build_forest}, consumed by record-pattern access
      in [dashboard_http_keeper].
    - {b forest builder} ({!build_forest}).
    - {b per-node JSON renderer} ({!tree_node_to_json})
      consumed by [dashboard_http_keeper] when assembling
      the per-keeper goal projection.
    - {b dashboard envelope} ({!dashboard_goals_tree_json})
      consumed by [server_dashboard_http] +
      [test/test_goal_metric_unevaluated].
    - {b per-goal detail} ({!goal_detail_json}) consumed
      by [server_dashboard_http].

    Internal helpers stay private at this boundary
    ([goal_status_color], [build_goal_events_projection],
    [flatten_tree], [stagnation_seconds_of_node],
    [keeper_metas_for_goal],
    [pending_approval_count_of_goal],
    [keeper_detail_json] +
    [goal_detail_keeper] type, every per-section
    sub-renderer consumed only inside the surface
    entries above). *)

(** {1 Tree node record} *)

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : Masc_domain.task list;
  last_activity_at : string;
  stagnation_seconds : int option;
  linked_keeper_names : string list;
  pending_approval_count : int;
  latest_keeper_ref : string option;
  latest_turn_ref : int option;
  activity_observation : string;
}
(** Per-goal projection node returned by
    {!build_forest}.  Concrete record because
    [dashboard_http_keeper] reaches the [.goal] /
    [.linked_keeper_names] / [.children] fields directly
    when assembling the per-keeper goal block. *)

(** {1 Flat goal projection} *)

val build_forest :
  config:Workspace.config ->
  goals:Goal_store.goal list ->
  tasks:Masc_domain.task list ->
  pending_approvals:Yojson.Safe.t list ->
  tree_node list
(** Projects every flat Goal as one top-level node. [children] remains an
    always-empty compatibility field in the JSON record; the Goal schema has
    no parent relation. Each node keeps its own direct task, approval,
    receipt/runtime, and activity observations. *)

(** {1 Per-node JSON renderer} *)

val tree_node_to_json :
  ?events_for_goal:(string -> Yojson.Safe.t list) ->
  tree_node ->
  Yojson.Safe.t
(** Renders a single {!tree_node} as JSON. The optional callback supplies
    per-goal lifecycle events and defaults to an empty timeline. *)

(** {1 Dashboard envelope} *)

val dashboard_goals_tree_json :
  config:Workspace.config -> Yojson.Safe.t
(** Returns the full goals dashboard envelope: forest +
    rolled-up summary + lifecycle event projection. Used
    by the [/api/dashboard/goals/tree] route and the
    regression test. *)

(** {1 Per-goal detail} *)

val goal_detail_json :
  config:Workspace.config ->
  goal_id:string ->
  (Yojson.Safe.t, string) result
(** Returns the per-goal detail envelope for [goal_id].
    [Error msg] when the goal is not in the tree. *)

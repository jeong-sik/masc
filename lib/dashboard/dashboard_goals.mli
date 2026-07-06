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
      [test/test_dashboard_goals].
    - {b per-goal detail} ({!goal_detail_json}) consumed
      by [server_dashboard_http] +
      [test/test_dashboard_goals].

    Internal helpers stay private at this boundary
    (~50 internal lets — [goal_status_color],
    [goal_health_string],
    [build_goal_verification_projection],
    [goal_policy_nodes],
    [flatten_tree], [convergence_of_node],
    [stagnation_seconds_of_node],
    [keeper_metas_for_goal],
    [linkage_diagnostics_of_node],
    [pending_approval_count_of_goal],
    [infra_risk_count_of_node],
    [keeper_detail_json] +
    [goal_detail_keeper] type, every per-section
    sub-renderer consumed only inside the surface
    entries above). *)

(** {1 Tree node record} *)

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : (Masc_domain.task * string) list;
  convergence : float;
      (** 0.0 .. 1.0 completion ratio. *)
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
(** Per-goal projection node returned by
    {!build_forest}.  Concrete record because
    [dashboard_http_keeper] reaches the [.goal] /
    [.linked_keeper_names] / [.children] fields directly
    when assembling the per-keeper goal block. *)

(** {1 Forest builder} *)

val build_forest :
  config:Workspace.config ->
  goals:Goal_store.goal list ->
  tasks:Masc_domain.task list ->
  tree_node list
(** Assembles the goal forest from [goals] / [tasks].
    Every root goal (no parent or parent outside [goals])
    becomes a top-level entry; convergence + health +
    badges + linkage + blocking summaries are folded in
    from the keeper / receipt / pending-approval state
    accessible via [config]. *)

val build_forest_result :
  config:Workspace.config ->
  goals:Goal_store.goal list ->
  tasks:Masc_domain.task list ->
  (tree_node list, string) result
(** Result-returning forest builder. Returns [Error] when the goal-task link
    registry cannot be read, so callers do not have to treat unreadable links as
    an empty registry. *)

(** {1 Per-node JSON renderer} *)

val tree_node_to_json :
  ?effective_policy_for_goal:
    (string -> Goal_verification.policy_snapshot option) ->
  ?open_request_for_goal:
    (string -> Goal_verification.goal_verification_request option) ->
  ?latest_request_for_goal:
    (string -> Goal_verification.goal_verification_request option) ->
  ?events_for_goal:(string -> Yojson.Safe.t list) ->
  tree_node ->
  Yojson.Safe.t
(** Renders a single {!tree_node} as JSON.  Optional
    callbacks supply per-goal verification policy /
    open-request / latest-request / event-timeline projections; defaults
    return [None] / [\[\]] so callers that don't need
    verification context can pass the bare node. *)

(** {1 Dashboard envelope} *)

val dashboard_goals_tree_json :
  config:Workspace.config -> Yojson.Safe.t
(** Returns the full goals dashboard envelope: forest +
    rolled-up summary + verification projection.  Used
    by the [/api/dashboard/goals/tree] route and the
    regression test. *)

val emit_all_goal_attainment_metrics :
  config:Workspace.config -> unit
(** Recomputes the goal forest and emits OTLP gauge metrics
    ([masc_goal_attainment_pct] + [masc_goal_attainment_measured])
    for every goal.  Safe to call from the background snapshot
    refresh loop. *)

(** {1 Per-goal detail} *)

val goal_detail_json :
  config:Workspace.config ->
  goal_id:string ->
  (Yojson.Safe.t, string) result
(** Returns the per-goal detail envelope for [goal_id].
    [Error msg] when the goal is not in the tree. *)

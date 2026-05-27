(** Dashboard_goals — operator goals dashboard surface:
    forest assembly, per-node JSON rendering, full tree
    JSON envelope, and per-goal detail.

    {b SSOT}: types and pure helpers come from
    {!Dashboard_goals_types} via [include] below.
    Each type has exactly one canonical definition
    in the owning submodule — do not redeclare here.

    External surface beyond the cascade (4 own-module entries):
    - {b forest builder} ({!build_forest}).
    - {b per-node JSON renderer} ({!tree_node_to_json})
      consumed by [dashboard_http_keeper] when assembling
      the per-keeper goal projection.
    - {b dashboard envelope} ({!dashboard_goals_tree_json})
      consumed by [server_dashboard_http] +
      [test/test_dashboard_goals].
    - {b per-goal detail} ({!goal_detail_json}) consumed
      by [server_dashboard_http] +
      [test/test_dashboard_goals]. *)

include module type of Dashboard_goals_types

(** {1 Forest builder} *)

val build_forest :
  config:Coord.config ->
  goals:Goal_store.goal list ->
  tasks:Masc_domain.task list ->
  tree_node list
(** Assembles the goal forest from [goals] / [tasks].
    Every root goal (no parent or parent outside [goals])
    becomes a top-level entry; convergence + health +
    badges + linkage + blocking summaries are folded in
    from the keeper / receipt / pending-approval state
    accessible via [config]. *)

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
  config:Coord.config -> Yojson.Safe.t
(** Returns the full goals dashboard envelope: forest +
    rolled-up summary + verification projection.  Used
    by the [/api/dashboard/goals/tree] route and the
    regression test. *)

(** {1 Per-goal detail} *)

val goal_detail_json :
  config:Coord.config ->
  goal_id:string ->
  (Yojson.Safe.t, string) result
(** Returns the per-goal detail envelope for [goal_id].
    [Error msg] when the goal is not in the tree. *)

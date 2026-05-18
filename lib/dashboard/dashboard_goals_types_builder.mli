(** Recursive goal-tree builder and runtime trust projection helpers. *)

open Dashboard_goals_types_accessor

val compute_convergence :
  Goal_store.goal ->
  (Masc_domain.task * string) list ->
  tree_node list ->
  float

val goal_policy_nodes :
  Goal_store.goal list -> Goal_verification.goal_policy_node list

val runtime_blocker_event_from_meta :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  Yojson.Safe.t option

val runtime_trust_from_receipt_fallback :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  Yojson.Safe.t ->
  Yojson.Safe.t

type build_context = {
  now_ts : float;
  all_tasks : Masc_domain.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_types.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
  latest_runtime_trusts : (string * Yojson.Safe.t) list;
}

val build_tree : build_context -> Goal_store.goal list -> Goal_store.goal -> tree_node

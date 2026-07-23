(** Recursive goal-tree builder and runtime trust projection helpers. *)

open Dashboard_goals_types_accessor

type build_context = {
  now_ts : float;
  all_tasks : Masc_domain.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_meta_contract.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
  latest_runtime_trusts : (string * Yojson.Safe.t) list;
  goal_task_index : (string, string list) Hashtbl.t;
}

val build_tree : build_context -> Goal_store.goal list -> Goal_store.goal -> tree_node

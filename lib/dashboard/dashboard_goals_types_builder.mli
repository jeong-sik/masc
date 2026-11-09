(** Goal tree-node builder and runtime trust projection helpers. *)

open Dashboard_goals_types_accessor

type build_context = {
  now_ts : float;
  all_tasks : Masc_domain.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_meta_contract.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
  runtime_trust_of : string -> Yojson.Safe.t option;
      (** The Keeper's runtime trust snapshot, [None] for a name that is not
          one of [keeper_metas]. [build_tree] asks only for the Keepers its
          goal's tasks are assigned to. *)
  goal_task_index : (string, string list) Hashtbl.t;
}

(** Pure projection: given a [build_context] snapshot, build the [tree_node]
    for [goal]. Goals are flat, so the node has no children. Applying
    [build_tree] to a context indexes the snapshot once; apply the result to
    each goal. *)
val build_tree : build_context -> Goal_store.goal -> tree_node

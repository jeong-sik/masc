(** Host-observed facts attached to one Auto Judge request.

    This projection is deliberately separate from the Keeper transcript. It
    gives the Judge typed task linkage, the resolved execution boundary, and
    repository-catalog identity without asking the model to infer those facts
    from prose. *)

val for_approval
  :  Keeper_approval_queue_rules_types.pending_approval
  -> Yojson.Safe.t

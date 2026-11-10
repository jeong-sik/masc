(** Current metrics-ledger tool audit for operator control snapshots. *)

val tool_audit_json :
  read_policy:Dashboard_projection_read.t ->
  Workspace.config -> Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** [Current] reads the actual metrics store; [Reuse] permits the existing
    per-Keeper projection cache. *)

(** Current metrics-ledger tool audit for operator control snapshots. *)

val cached_tool_audit_json :
  Workspace.config -> Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

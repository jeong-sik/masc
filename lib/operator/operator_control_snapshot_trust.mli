(** Runtime-trust JSON helpers for operator control snapshots. *)

val compact_keeper_runtime_trust_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

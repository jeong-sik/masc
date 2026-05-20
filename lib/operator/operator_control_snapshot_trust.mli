(** Runtime-trust JSON helpers for operator control snapshots. *)

val compact_keeper_runtime_trust_json :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> Yojson.Safe.t

val degraded_keeper_snapshot_row : Keeper_types.keeper_meta -> Yojson.Safe.t

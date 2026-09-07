(** Keeper identity-field builders for operator control snapshots. *)

val keeper_runtime_identity_fields :
  Keeper_meta_contract.keeper_meta -> (string * Yojson.Safe.t) list
(** Live identity fields with runtime canonicalization. *)

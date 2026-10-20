(** Keeper identity-field builders for operator control snapshots. *)

val keeper_runtime_identity_fields :
  Keeper_meta_contract.keeper_meta -> (string * Yojson.Safe.t) list
(** Live identity fields with runtime canonicalization. *)

val keeper_current_task_field :
  Keeper_meta_contract.keeper_meta -> string * Yojson.Safe.t
(** [("current_task_id", id)] from the keeper's meta, [null] when it holds no
    task. *)

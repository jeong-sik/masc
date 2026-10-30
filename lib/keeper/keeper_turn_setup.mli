(** Keeper_turn_setup — keeper setup helpers.

    Extracted from keeper_turn.ml. *)

(** Resolve a keeper by name and return its effective meta record.
    Returns [Error] if the keeper does not exist, the meta is unreadable,
    or TOML/profile overlay cannot be applied. *)
val ensure_keeper_exists :
  ctx:_ Keeper_types_profile.context ->
  name:string ->
  (Keeper_meta_contract.keeper_meta, string) result

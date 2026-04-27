(** Keeper_turn_setup — keeper setup helpers.

    Extracted from keeper_turn.ml. *)

(** Resolve a keeper by name and return its meta record. Returns
    [Error] if the keeper does not exist or the meta is unreadable. *)
val ensure_keeper_exists :
  ctx:_ Keeper_types.context ->
  name:string ->
  (Keeper_types.keeper_meta, string) result

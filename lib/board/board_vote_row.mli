(** Current persisted vote row. Identifier validation retains its existing
    effects on the caller's thread. No persistence or store mutation. *)
val of_yojson :
  Yojson.Safe.t ->
  (Board_vote_key.t * Board_types.vote_direction * float) option

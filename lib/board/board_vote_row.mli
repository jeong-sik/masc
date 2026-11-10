(** Current persisted vote row. Identifier validation retains its existing
    effects on the caller's thread. No persistence or store mutation. *)
val direction_to_string : Board_types.vote_direction -> string
val to_yojson :
  Board_vote_key.t * Board_types.vote_direction * float -> Yojson.Safe.t
(** Encode the typed vote identity, its voter and the retained cast timestamp
    using the same row shape as the decoder. *)
val of_yojson :
  Yojson.Safe.t ->
  (Board_vote_key.t * Board_types.vote_direction * float) option

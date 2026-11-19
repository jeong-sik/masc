(** The wire shape of one {!Keeper_turn_log.stimulus}: an object with its
    [kind] and its ids and names as text, all at one level. *)

val to_json : Keeper_turn_log.stimulus -> Yojson.Safe.t

(** Every object has exactly the fields of its kind. *)
val of_json
  :  Yojson.Safe.t
  -> (Keeper_turn_log.stimulus, Keeper_memory_os_types.wire_error) result

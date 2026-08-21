(** Tool-neutral workflow rejection payload builder. *)

val payload
  :  ?rule_id:string
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> string
  -> Yojson.Safe.t

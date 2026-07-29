(** Tool-neutral workflow rejection payload builder. *)

val payload
  :  ?rule_id:string
  -> ?recoverable:bool
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> string
  -> Yojson.Safe.t

val payload_json
  :  ?rule_id:string
  -> ?recoverable:bool
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> string
  -> string

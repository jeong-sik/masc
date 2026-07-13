(** Tool-neutral workflow rejection payload builder. *)

val payload
  :  ?rule_id:string
  -> ?tool_suggestion:string
  -> ?hint:string
  -> ?scope_policy:string
  -> ?recoverable:bool
  -> ?alternatives:string list
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> string
  -> Yojson.Safe.t

val payload_json
  :  ?rule_id:string
  -> ?tool_suggestion:string
  -> ?hint:string
  -> ?scope_policy:string
  -> ?recoverable:bool
  -> ?alternatives:string list
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> string
  -> string

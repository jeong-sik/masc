(** Tool-neutral workflow rejection payload builder.

    When supplied, [scope_policy] must be the current diagnostic value
    ["observe"]; removed or unknown values are rejected. *)

val payload
  :  ?rule_id:string
  -> ?scope_policy:string
  -> ?recoverable:bool
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> string
  -> Yojson.Safe.t

val payload_json
  :  ?rule_id:string
  -> ?scope_policy:string
  -> ?recoverable:bool
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> string
  -> string

(** Exact mention extraction and matching. Routing policy belongs to callers. *)

val extract : string -> string option
(** Extract the exact target from [@target] or [@@target]. Fleet broadcast
    syntax has priority over direct mentions, matching the production contract. *)

val is_mentioned : string -> string -> bool
(** Check whether content contains an exact direct mention for a target *)

val any_mentioned : targets:string list -> string -> bool
(** Check whether content contains an exact direct mention for any target *)

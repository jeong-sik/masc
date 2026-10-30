(** The host clock side of {!Wiki_log}: the wiki core reads [log.md] without
    consulting a clock or a time zone, and the callers that read a real log
    pass {!local_minute} to {!Wiki_log.parse}. *)

val local_minute : year:int -> month:int -> day:int -> hour:int -> minute:int -> float option
(** The Unix time at the start of the given minute, read in the host's local
    time zone as the journal writer stamps it. [None] when the minute does not
    exist on the calendar: the conversion moves an out-of-range day into the
    next month, so a day that changes on the way through is refused. *)

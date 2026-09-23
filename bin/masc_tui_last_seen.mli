(** How long ago a row was last seen, as a span rather than a clock.

    [text ~now last_seen] reads the wire's RFC 3339 stamp and answers the
    span since it: ["1s"], ["16h48m"], ["2d10h"]. An empty stamp is
    ["never"]. A stamp that will not parse, or that sits ahead of [now], is
    returned as it arrived -- a span would claim a measurement that was not
    made. *)

val text : now:float -> string -> string

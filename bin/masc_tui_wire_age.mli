(** How long ago a wire timestamp was, as a span rather than a clock.

    [text ~now stamp] reads an RFC 3339 stamp and answers the span since it:
    ["1s"], ["7h48m"], ["1d21h"]. An empty stamp is ["never"]. A stamp that
    will not parse, or that sits ahead of [now], is returned as it arrived --
    a span would claim a measurement that was not made. *)

val text : now:float -> string -> string

(** The seat-routes block of a Fusion run's detail: for every seat of the
    deliberation, the route it was given and the runtime that answered, with
    each candidate that failed before it listed underneath.

    Pure, so a test reads the block as the operator will: one line per seat,
    the failed attempts indented under their seat, in the order the sink
    recorded them. *)

val lines : Masc.Tui_decode.fusion_seat_route list -> string list
(** [<seat> · route <route> → answered by <runtime>] per seat, a seat nobody
    answered saying so instead, then [<runtime>: <code> <detail>] indented
    for each failed attempt. Seats are spelled as the tool ledger spells its
    actors: [panel/<id>] and [judge/<role>/<identity>]. Text is made safe for
    the terminal here. *)

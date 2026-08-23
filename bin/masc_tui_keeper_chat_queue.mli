(** Messages typed while a turn was running, waiting for the next one.

    Dispatch is serialized on one in-flight request, so a second Enter used to
    be answered with "Keeper message already in progress" and the text was
    gone. Holding it is what an operator means by pressing Enter twice, and
    what every other agent console does.

    Order is submission order and nothing reorders it: two lines typed as one
    thought arrive as one thought. The keeper travels with the text because the
    operator can switch keepers while a turn runs, and a queued line must reach
    the keeper it was written to rather than whoever is selected when it goes. *)

type t

val empty : t
val is_empty : t -> bool
val length : t -> int

val waiting : t -> (string * string) list
(** Oldest first, as [(keeper_name, text)] — what the pane draws. *)

val cap : int
(** How many lines may wait. A turn that never settles would otherwise grow
    this without limit. *)

val push : t -> keeper_name:string -> string -> (t * int, string) result
(** Append one line. [Ok (queue, waiting)] carries how many are now waiting, so
    the caller can say it. [Error] at {!cap}: refused and named, rather than
    dropping the oldest and leaving the operator to notice a line went
    missing. *)

val pop : t -> ((string * string) * t) option
(** Take the oldest. [None] when nothing waits. *)

val take_newest : t -> ((string * string) * t) option
(** Take the newest waiting line. The newest is the one an operator just
    typed and the one a mis-send hits: cancel drops it, and pulling it back
    into the composer is the edit. The line has not been dispatched, so both
    are local decisions with nothing to undo on the server. [None] when
    nothing waits. *)

val drop_for_keeper : t -> keeper_name:string -> t
(** Forget what was waiting for one keeper. Used when that keeper is gone: a
    line cannot be delivered to a keeper that is no longer registered, and
    holding it forever would make the count say work is pending that never
    moves. *)

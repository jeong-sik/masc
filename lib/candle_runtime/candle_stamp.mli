(** The times a runtime step puts on a ledger row (RFC-goal-candle-ledger 3.1).

    A step writes two kinds of time. Its own [at] comes from the clock it was
    given. Every other time is copied from text that another store wrote, and
    the ledger takes it only in its own form. A step that meets a time in any
    other form refuses, so the row it would have written is not written. *)

val at : now:(unit -> float) -> (Candle_time.t, string) result
(** The clock's reading, to the whole second. [Error] when the reading is
    outside the calendar. *)

val copied : what:string -> string -> (Candle_time.t, string) result
(** A time copied from another store's text. [what] names it in the error. *)

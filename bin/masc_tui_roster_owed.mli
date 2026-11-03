(** What the Keeper roster owes its server reading after the server
    announced a change (RFC-0481 §3.3).

    [keeper_row_changed] names one Keeper, and that Keeper's row is read
    alone ([GET /api/v1/gate/keepers?name=<keeper>]).
    [keeper_roster_changed] changes every row, and the roster is read whole
    with [fresh=true]. Two or more Keepers due at once are read whole as
    well: one request instead of one per Keeper.

    One read runs at a time. Each owed value follows {!Masc_tui_owed_read}:
    a read is owed until one that began after the change succeeds, and a
    failed read waits longer with each failure in a row. A whole read covers
    every owed row. Nothing here performs I/O or reads a clock. *)

type t

type read =
  | Read_row of string  (** That Keeper's row alone. *)
  | Read_roster  (** The whole roster, with [fresh=true]. *)

val settled : t

val row_changed : keeper_name:string -> t -> t
(** The server announced that this Keeper's row may have changed. *)

val roster_changed : t -> t
(** Every row may have changed, or the reader cannot place one row. *)

val reading : t -> bool
(** A read this value started has not answered. *)

val next_read : now:float -> t -> read option
(** The read to start now. [None] while a read is in flight or nothing is
    due. *)

val started : read -> t -> t
val succeeded : read -> t -> t
val failed : retry_s:float -> max_retry_s:float -> now:float -> read -> t -> t

val abandoned : t -> t
(** The read in flight will not answer: another read took the roster, or the
    read never ran. What it was reading is owed again. *)

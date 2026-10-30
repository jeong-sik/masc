(** The name a client uses to stop the execution that holds a Keeper's turn
    slot.

    The Keeper Owner mints one token when it starts a child, publishes it in
    {!Keeper_owner.turn_in_flight}, and compares it in
    {!Keeper_owner.interrupt_turn}. The token and the slot share one lifetime:
    a running turn always has a stop handle, and a finished turn's token can
    never name its successor. The inner agent switch a turn registers in
    {!Keeper_registry} is not involved; it ends before the child does, which
    is exactly the window in which a client still needs to stop the child. *)

type t

val fresh : unit -> t
(** A new random identity. Safe to call from any domain. *)

val equal : t -> t -> bool

val to_string : t -> string
(** The canonical UUID text sent on the wire. *)

val of_string : string -> (t, string) result
(** Parse the wire text of a token. The error is the message a route returns
    for a malformed field. Any UUID version is accepted: the token is an
    opaque identity, and only [equal] against a live slot gives it meaning. *)

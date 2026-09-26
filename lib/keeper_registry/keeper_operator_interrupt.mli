(** Typed operator cancellation shared with official-client runtimes below the
    Keeper owner. *)

exception Operator_interrupt

val is_operator_interrupt : exn -> bool
(** True only when every member of an Eio exception wrapper is this operator
    cancellation. A mixed error remains ambiguous. *)

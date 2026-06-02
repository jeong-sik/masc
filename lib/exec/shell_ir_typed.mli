include module type of Shell_ir_typed_types

val of_simple : Shell_ir.simple -> wrapped
val to_simple : ('i, 'o, 'r, 's) command -> Shell_ir.simple
val risk : wrapped -> risk
val sandbox : wrapped -> sandbox

val is_generic : wrapped -> bool
(** [true] for the [Generic] escape hatch, [false] for every typed
    constructor. RFC-0208 P1 typed-coverage instrument. *)

val pp : Format.formatter -> wrapped -> unit

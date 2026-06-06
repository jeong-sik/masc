include module type of Shell_ir_typed_types

val of_simple : Shell_ir.simple -> wrapped
val to_simple : ('i, 'o, 'r, 's) command -> Shell_ir.simple
val risk : wrapped -> risk
val sandbox : wrapped -> sandbox

val is_generic : wrapped -> bool
(** [true] for the [Generic] escape hatch, [false] for every typed
    constructor. RFC-0208 P1 typed-coverage instrument. *)

val pp : Format.formatter -> wrapped -> unit

val path_args : wrapped -> string list
(** Extract local filesystem path arguments from a typed command.
    Returns all path-like string fields (read and write targets).
    Consumer filters by risk class for validation scope.
    Exhaustive match — new constructors force an explicit decision. *)

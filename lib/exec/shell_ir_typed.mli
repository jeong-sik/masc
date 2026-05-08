include module type of Shell_ir_typed_types

val of_simple : Shell_ir.simple -> wrapped
val to_simple : ('i, 'o, 'r, 's) command -> Shell_ir.simple
val risk : wrapped -> risk
val sandbox : wrapped -> sandbox
val pp : Format.formatter -> wrapped -> unit

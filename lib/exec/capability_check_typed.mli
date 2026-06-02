(** Capability_check_typed — GADT-based capability derivation.

    Unlike [Capability_check.of_simple] which walks an untyped [Shell_ir.t]
    and re-parses literal arguments, this module extracts capabilities
    directly from a typed command where the constructor already encodes the
    operation semantics.  The result is identical to the untyped walker
    for well-formed commands, but the extraction is total (no [None]
    fallthrough) because the GADT constructor guarantees the shape. *)

val of_command : Shell_ir_typed.wrapped -> Capability.t list

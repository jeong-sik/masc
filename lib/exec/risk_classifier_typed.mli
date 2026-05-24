(** Risk_classifier_typed — GADT-based risk classification.

    Exhaustive match on the GADT.  Adding a new constructor forces an arm
    here, so the risk mapping can never silently default to a wrong class. *)

val of_command : Shell_ir_typed.wrapped -> Bin.risk_class

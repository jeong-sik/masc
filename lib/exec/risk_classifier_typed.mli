(** Risk_classifier_typed — GADT-based risk classification.

    The risk level is already encoded in the GADT parameter ['r]; this
    module projects it back to the external [Bin.risk_class] type so that
    the approval policy can consume it without knowing about the GADT. *)

val of_command : Shell_ir_typed.wrapped -> Bin.risk_class

(** Shared structural OAS timeout message predicates. *)

val is_structural : string -> bool
(** [is_structural message] returns [true] when [message] is one of the
    timeout-budget diagnostics that should be classified structurally by
    keeper turn-driver code. *)

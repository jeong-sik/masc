(** Tool projection of a refusal decided from the authoritative Task snapshot.
    This module formats the lifecycle's decision; it performs no admission or
    ownership check and does not select another tool for the caller. *)

val payload : Masc_domain.Task_error.transition_rejected -> Yojson.Safe.t

(** Sidecar reconciliation state variants + bijection helpers. *)

type desired_state =
  | Desired_running
  | Desired_stopped

type observed_state =
  | Observed_available
  | Observed_unavailable

type reconcile_result =
  | Reconcile_started
  | Reconcile_noop of string

val desired_state_to_string : desired_state -> string
val desired_state_of_string : string -> desired_state option
val observed_state_to_string : observed_state -> string
val reconcile_result_to_string : reconcile_result -> string

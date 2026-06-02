(** Sidecar reconciliation state variants + bijection helpers.

    [desired_state] — operator-set goal (Running or Stopped).
    [observed_state] — observed runtime (Available or Unavailable).
    [reconcile_result] — outcome of a single reconcile attempt
    (Started, or Noop with an explanation).

    Verbatim extract from [Server_routes_http_routes_sidecar]; the
    parent retains transparent variant aliases so the .mli concrete
    declarations and downstream record fields ([desired_record],
    [attempt_record]) continue to type-check unchanged. *)

type desired_state =
  | Desired_running
  | Desired_stopped

type observed_state =
  | Observed_available
  | Observed_unavailable

type reconcile_result =
  | Reconcile_started
  | Reconcile_noop of string

let desired_state_to_string = function
  | Desired_running -> "running"
  | Desired_stopped -> "stopped"
;;

let desired_state_of_string = function
  | "running" -> Some Desired_running
  | "stopped" -> Some Desired_stopped
  | _ -> None
;;

let observed_state_to_string = function
  | Observed_available -> "available"
  | Observed_unavailable -> "unavailable"
;;

let reconcile_result_to_string = function
  | Reconcile_started -> "started"
  | Reconcile_noop reason -> "noop:" ^ reason
;;

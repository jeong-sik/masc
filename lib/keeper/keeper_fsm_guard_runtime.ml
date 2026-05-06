(* Runtime safety wrapper for [@@fsm_guard]-bearing identity helpers.

   See keeper_fsm_guard_runtime.mli for the contract. *)

let refresh_policy_for_test () = ()
let assert_mode_for_test () = true

let bump_counter ~action ~stage =
  Prometheus.inc_counter Prometheus.metric_fsm_guard_violation
    ~labels:[ ("action", action); ("stage", stage) ]
    ()

let wrap_unit ~action ~stage thunk =
  try thunk ()
  with Assert_failure _ as exn ->
    bump_counter ~action ~stage;
    raise exn

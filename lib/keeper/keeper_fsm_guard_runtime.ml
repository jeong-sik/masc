(* Runtime safety wrapper for [@@fsm_guard]-bearing identity helpers.

   See keeper_fsm_guard_runtime.mli for the contract. *)

let policy_assert_mode = ref None

let read_assert_env () =
  match Sys.getenv_opt "MASC_FSM_GUARD_ASSERT" with
  | Some "0" | Some "false" | Some "FALSE" -> false
  | _ -> true

let assert_mode () =
  match !policy_assert_mode with
  | Some v -> v
  | None ->
      let v = read_assert_env () in
      policy_assert_mode := Some v;
      v

(* tla-lint: allow-mutation: test hook — reset env-cached policy between tests *)
let refresh_policy_for_test () = policy_assert_mode := None
let assert_mode_for_test () = assert_mode ()

let bump_counter ~action ~stage =
  Prometheus.inc_counter Prometheus.metric_fsm_guard_violation
    ~labels:[ ("action", action); ("stage", stage) ]
    ()

let wrap_unit ~action ~stage thunk =
  let hard = assert_mode () in
  try thunk ()
  with Assert_failure _ as exn ->
    bump_counter ~action ~stage;
    if hard then raise exn else ()

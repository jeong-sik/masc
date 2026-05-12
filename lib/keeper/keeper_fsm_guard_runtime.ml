(* Runtime safety wrapper for [@@fsm_guard]-bearing identity helpers.

   See keeper_fsm_guard_runtime.mli for the contract. *)

let refresh_policy_for_test () = ()
let assert_mode_for_test () = true

let bump_counter ~action ~stage =
  Prometheus.inc_counter Prometheus.metric_fsm_guard_violation
    ~labels:[ ("action", action); ("stage", stage) ]
    ()

(* Any exception escaping a [@@fsm_guard]-bearing identity helper is the
   spec-violation channel for instrumentation purposes: the wrapped thunk's
   only job is to dispatch a (from, to) pair against a total resolver and
   raise on a forbidden pair.  Historically that raise was [Assert_failure]
   (PPX-injected) or [Invalid_argument] (validators embedding the pair in a
   string).  As of RFC-0072 Phase 5 the validators raise typed exceptions
   ([Keeper_registry.Cascade_transition_violation] /
   [Turn_phase_transition_violation]); naming those here would create a
   module dependency cycle ([Keeper_registry] already depends on this
   module), so the catch is widened to all exceptions.  The counter is
   bumped and the exception re-raised unchanged. *)
let wrap_unit ~action ~stage thunk =
  try thunk () with
  | exn ->
    bump_counter ~action ~stage;
    raise exn

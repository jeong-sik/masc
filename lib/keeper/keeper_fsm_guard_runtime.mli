(** Runtime safety wrapper for [@@fsm_guard]-bearing identity helpers.

    Cycle 43 / Tier I3 follow-up to the smoke test at
    [keeper_turn_fsm.ml:118] (PR #11377 era). The PPX
    [@@fsm_guard "<bool-expr>"] injects [assert (<bool-expr>);] into
    the function body.

    [wrap_unit] runs a [unit -> unit] thunk under that contract:
    catches [Assert_failure], bumps the
    [Prometheus.metric_fsm_guard_violation] counter labelled with
    [action] / [stage], and re-raises.  FSM contract violations are
    fail-closed in production and tests; [MASC_FSM_GUARD_ASSERT] is no
    longer a runtime soft-mode escape hatch.

    The thunk is expected to call an identity helper of return type
    [unit] (a function whose only purpose is to carry the
    [@@fsm_guard] attribute). Non-[Assert_failure] exceptions
    propagate unchanged — only the spec-violation channel is
    intercepted. *)

val wrap_unit :
  action:string ->
  stage:string ->
  (unit -> unit) ->
  unit

(** Compatibility no-op retained for older tests.  The guard policy no
    longer reads [MASC_FSM_GUARD_ASSERT]. *)
val refresh_policy_for_test : unit -> unit

(** Always [true]: guard violations always re-raise after incrementing
    the violation counter. *)
val assert_mode_for_test : unit -> bool

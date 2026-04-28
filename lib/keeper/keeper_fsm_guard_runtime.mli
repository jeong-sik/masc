(** Runtime safety wrapper for [@@fsm_guard]-bearing identity helpers.

    Cycle 43 / Tier I3 follow-up to the smoke test at
    [keeper_turn_fsm.ml:118] (PR #11377 era). The PPX
    [@@fsm_guard "<bool-expr>"] injects [assert (<bool-expr>);] into
    the function body. On the heartbeat / task-acquisition hot paths
    that fire every cycle, raising [Assert_failure] would crash the
    keeper on a transient drift — undesirable in production but
    desirable in tests.

    [wrap_unit] runs a [unit -> unit] thunk under that contract:
    catches [Assert_failure], bumps the
    [Prometheus.metric_fsm_guard_violation] counter labelled with
    [action] / [stage], and either swallows the failure (default,
    "counter mode") or re-raises ([MASC_FSM_GUARD_ASSERT=1], "assert
    mode" — for tests, smoke runs, and CI).

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

(** Force a re-read of [MASC_FSM_GUARD_ASSERT] for tests that need to
    flip the policy mid-run. Production code never calls this. *)
val refresh_policy_for_test : unit -> unit

(** Inspect the cached policy. [true] iff [MASC_FSM_GUARD_ASSERT=1] at
    module init or after [refresh_policy_for_test]. *)
val assert_mode_for_test : unit -> bool

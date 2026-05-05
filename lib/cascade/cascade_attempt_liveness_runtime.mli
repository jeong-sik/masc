(** Cascade attempt-liveness runtime helpers (RFC-0022 PR-2/4).

    Pure decision helpers that bridge {!Cascade_attempt_liveness} (the
    PR-1 FSM) to the side effects callers will need: Prometheus
    counter increment, log line, and the cascade-FSM-visible verdict
    (advance vs continue).

    {b Production effect of this PR}: zero. No call site in
    [cascade_runtime.ml] or anywhere else consumes these helpers yet.
    Wiring lands in PR-3 of the RFC-0022 stack.

    @stability Evolving
    @since 0.190.0 *)

(** {1 Verdict observed by the cascade FSM} *)

type verdict =
  | Continue_attempt
      (** Liveness gate did not fire, or fired but mode is non-enforcing.
          Caller must NOT advance the cascade FSM on this verdict. *)

  | Abort_attempt of Cascade_attempt_liveness.failure
      (** Liveness gate fired and mode is [Enforce]. Caller must
          advance the cascade FSM with the carried failure class. *)

(** {1 Side-effect descriptor}

    Returned to the caller alongside the {!verdict}. The caller
    performs the actual emission (Prometheus, Log) so this module
    stays IO-free and unit-testable. *)

type side_effect =
  | Nothing
      (** No event to emit on this transition. *)

  | Record_kill of {
      kind : Cascade_attempt_liveness.failure;
      mode_label : string;
          (** [observe] or [enforce] at the time of the kill. *)
    }
      (** Kill observed; caller increments
          [masc_cascade_attempt_liveness_kill_total]
          and emits a structured log line. *)

(** {1 Decision step}

    Wraps {!Cascade_attempt_liveness.step} with mode awareness:

    | Underlying FSM output | Mode | verdict | side_effect |
    |-----------------------|------|---------|-------------|
    | {!Cascade_attempt_liveness.Continue}  | any | [Continue_attempt] | [Nothing] |
    | {!Cascade_attempt_liveness.Completed} | any | [Continue_attempt] | [Nothing] |
    | {!Cascade_attempt_liveness.Outcome f} | [Off]     | [Continue_attempt] | [Nothing] |
    | {!Cascade_attempt_liveness.Outcome f} | [Observe] | [Continue_attempt] | [Record_kill] |
    | {!Cascade_attempt_liveness.Outcome f} | [Enforce] | [Abort_attempt f]  | [Record_kill] |

    The [Completed] case is also reported as [Continue_attempt]
    because the *cascade-attempt-level liveness* contract has nothing
    to say about success — the caller's existing accept-predicate
    decides what success means. *)

val decide :
  mode:Env_config_keeper.CascadeAttemptLiveness.mode ->
  Cascade_attempt_liveness.output ->
  verdict * side_effect
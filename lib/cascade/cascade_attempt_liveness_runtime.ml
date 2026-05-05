(** Cascade attempt-liveness runtime helpers (RFC-0022 PR-2/4).

    Pure decision; see {!Cascade_attempt_liveness_runtime} mli for the
    decision table. *)

module Mode = Env_config_keeper.CascadeAttemptLiveness

type verdict =
  | Continue_attempt
  | Abort_attempt of Cascade_attempt_liveness.failure

type side_effect =
  | Nothing
  | Record_kill of {
      kind : Cascade_attempt_liveness.failure;
      mode_label : string;
    }

let decide
    ~(mode : Mode.mode)
    (out : Cascade_attempt_liveness.output)
    : verdict * side_effect
  =
  match out, mode with
  | Cascade_attempt_liveness.Continue, _ -> (Continue_attempt, Nothing)
  | Cascade_attempt_liveness.Completed, _ -> (Continue_attempt, Nothing)
  | Cascade_attempt_liveness.Outcome _, Mode.Off ->
      (Continue_attempt, Nothing)
  | Cascade_attempt_liveness.Outcome failure, Mode.Observe ->
      ( Continue_attempt
      , Record_kill { kind = failure; mode_label = Mode.mode_label Mode.Observe } )
  | Cascade_attempt_liveness.Outcome failure, Mode.Enforce ->
      ( Abort_attempt failure
      , Record_kill { kind = failure; mode_label = Mode.mode_label Mode.Enforce } )

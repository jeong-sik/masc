let build
      ~recorded_at
      ?slot_release_at_phase
      ?productive_phase_elapsed_ms
      ?retry_phase_elapsed_ms
      ~(from_cascade : Cascade_name.t)
      ~(retry : Keeper_error_classify.degraded_retry)
      ~(outcome : Keeper_execution_receipt.cascade_rotation_outcome)
      (err : Agent_sdk.Error.sdk_error)
  : Keeper_execution_receipt.cascade_rotation_attempt
  =
  { from_cascade
  ; to_cascade =
      (match Cascade_name.of_string retry.next_cascade with
       | Ok t -> t
       | Error (`Invalid_prefix | `Empty) ->
         Log.Misc.warn
           "rotation_attempt: next_cascade %S is not a qualified cascade name, \
            falling back to from_cascade"
           retry.next_cascade;
         from_cascade)
  ; reason = retry.fallback_reason
  ; outcome
  ; slot_release_at_phase
  ; productive_phase_elapsed_ms
  ; retry_phase_elapsed_ms
  ; error_kind =
      Some
        (Keeper_execution_receipt.error_kind_of_string
           (Keeper_agent_error.sdk_error_kind err))
  ; error_message = Some (Agent_sdk.Error.to_string err)
  ; recorded_at
  }
;;

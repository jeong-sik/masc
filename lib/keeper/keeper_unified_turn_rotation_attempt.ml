let build
      ~recorded_at
      ?slot_release_at_phase
      ?productive_phase_elapsed_ms
      ?retry_phase_elapsed_ms
      ~(from_cascade : Keeper_execution_receipt.cascade_name)
      ~(retry : Keeper_error_classify.degraded_retry)
      ~(outcome : Keeper_execution_receipt.cascade_rotation_outcome)
      (err : Agent_sdk.Error.sdk_error)
  : Keeper_execution_receipt.cascade_rotation_attempt
  =
  { from_cascade
  ; to_cascade = Keeper_execution_receipt.cascade_name_of_string retry.next_cascade
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

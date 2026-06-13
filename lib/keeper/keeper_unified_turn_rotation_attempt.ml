let build
      ~recorded_at
      ?productive_phase_elapsed_ms
      ?retry_phase_elapsed_ms
      ~(from_runtime : string)
      ~(retry : Keeper_error_classify.degraded_retry)
      ~(outcome : Keeper_execution_receipt.runtime_rotation_outcome)
      (err : Agent_sdk.Error.sdk_error)
  : Keeper_execution_receipt.runtime_rotation_attempt
  =
  { from_runtime
  ; (* RFC-0206: runtime-name validation moved to the TOML load boundary; a
       runtime id is a raw string accepted as-is (no prefix check here). *)
    to_runtime = retry.next_runtime
  ; reason = retry.fallback_reason
  ; outcome
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

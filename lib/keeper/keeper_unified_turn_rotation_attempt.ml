let build
      ~recorded_at
      ?productive_phase_elapsed_ms
      ?retry_phase_elapsed_ms
      ~(from_runtime : string)
      ~(retry : Keeper_error_classify.degraded_retry)
      ~(outcome : Keeper_execution_receipt.runtime_rotation_outcome)
      (err : Agent_core.Error.t)
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
        (Agent_core.Error.(category err |> category_label)
         |> Keeper_execution_receipt.error_kind_of_string)
  ; error_message = Some (Agent_core.Error.to_string err)
  ; recorded_at
  }
;;

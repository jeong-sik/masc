(** Pure reducer for runtime rotation attempt receipt rows.

    The keeper turn driver owns impure timing and mutable accumulation. This
    module owns the deterministic projection from a degraded retry decision plus
    its terminal error into the receipt row persisted at the end of the turn. *)

val build
  :  recorded_at:string
  -> ?productive_phase_elapsed_ms:int
  -> ?retry_phase_elapsed_ms:int
  -> from_runtime:string
  -> retry:Keeper_error_classify.degraded_retry
  -> outcome:Keeper_execution_receipt.runtime_rotation_outcome
  -> Agent_sdk.Error.sdk_error
  -> Keeper_execution_receipt.runtime_rotation_attempt

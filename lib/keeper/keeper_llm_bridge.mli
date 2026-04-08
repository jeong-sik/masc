(* lib/keeper/keeper_llm_bridge.mli *)

(** Runs a generic Eio execution (usually an OAS Agent.run or Model.call) with a strict
    structural timeout. If the execution is cancelled by a timeout or global stop,
    the exception is caught, OAS-local context mutations are discarded
    (functional rollback), external tool side effects are not reverted,
    and an OAS timeout error is returned. *)
val run_with_timeout_and_fallback :
  timeout_s:float ->
  (unit -> ('a, Oas.Error.sdk_error) result) ->
  ('a, Oas.Error.sdk_error) result

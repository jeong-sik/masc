(* lib/keeper/keeper_llm_bridge.mli *)

(** Runs a generic Eio execution (usually an OAS Agent.run or Model.call) with a strict
    structural timeout.

    - Timeout: OAS-local context mutations are discarded (functional rollback),
      external tool side effects are not reverted, returns [Error (Agent_sdk.Error.Api Timeout)].
    - Cancellation (server shutdown / parent fiber cancel): re-raises
      [Eio.Cancel.Cancelled] so the caller exits immediately without retrying.

    @raises Eio.Cancel.Cancelled when the parent fiber/switch is cancelled. *)
val run_with_timeout_and_fallback :
  timeout_s:float ->
  (unit -> ('a, Agent_sdk.Error.sdk_error) result) ->
  ('a, Agent_sdk.Error.sdk_error) result

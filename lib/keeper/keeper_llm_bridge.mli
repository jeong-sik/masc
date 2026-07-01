(* lib/keeper/keeper_llm_bridge.mli *)

val with_hitl_approval_headroom : float -> float
(** Raise an OAS bridge timeout floor above the longest active HITL
    approval wait. This keeps operator approval latency from being surfaced as
    an OAS/provider timeout before the approval queue itself resolves or
    expires. *)

type cancel_classification =
  | Unknown_cancel
  | Inner_timeout_cancel
  | Routine_parent_cancel
(** Caller-provided cancellation context.  [Routine_parent_cancel] is only for
    explicit parent/supervisor cancellation paths that are expected to re-raise;
    default [Unknown_cancel] cancellations carrying [Eio.Time.Timeout] are
    classified as [Inner_timeout_cancel] so provider/runtime timeout noise stays
    separate from unknown parent cancellation. *)

(** Runs a generic Eio execution (usually an OAS Agent.run or Model.call) with a strict
    structural timeout.

    - Timeout: OAS-local context mutations are discarded (functional rollback),
      external tool side effects are not reverted, returns [Error (Agent_sdk.Error.Api Timeout)].
    - Missing Eio clock: returns [Error (Agent_sdk.Error.Internal _)] without
      running the function because the timeout cannot be enforced.
    - Cancellation (server shutdown / parent fiber cancel): re-raises
      [Eio.Cancel.Cancelled] so the caller exits immediately without retrying.

    @raises Eio.Cancel.Cancelled when the parent fiber/switch is cancelled. *)
val run_with_timeout_and_fallback
  :  ?cancel_classification:cancel_classification
  -> timeout_s:float
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result

module For_testing : sig
  val cancelled_timeout_exceeded : timeout_s:float -> wall:float -> exn -> bool
end

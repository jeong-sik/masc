(* lib/keeper/keeper_llm_bridge.mli *)

type cancel_classification =
  | Unknown_cancel
  | Inner_timeout_cancel
  | Routine_parent_cancel
(** Caller-provided cancellation context.  [Routine_parent_cancel] is only for
    explicit parent/supervisor cancellation paths that are expected to re-raise;
    default [Unknown_cancel] cancellations carrying [Eio.Time.Timeout] are
    classified as [Inner_timeout_cancel] so provider/runtime timeout noise stays
    separate from unknown parent cancellation. *)

(** Runs a generic Eio execution (usually an OAS Agent.run or Model.call).

    [timeout_s] is an advisory budget only — it does NOT force-kill the
    execution. A wall-clock budget that killed a still-streaming provider call
    turned slow-but-healthy turns into kill -> retry churn that never produced a
    result, so the call runs to natural completion instead (fail-open directive;
    RFC-0305 non-reintroduction rule).

    - Slow call: runs to completion and returns the function's own result; it is
      not interrupted for overrunning [timeout_s].
    - Inner transport timeout: if the underlying provider call raises
      [Eio.Time.Timeout] on its own connect/idle deadline, that is surfaced as
      [Error (Agent_sdk.Error.Api Timeout)] (OAS-local context rollback only;
      external tool side effects are not reverted).
    - Missing Eio clock: returns [Error (Agent_sdk.Error.Internal _)] without
      running the function (the Eio environment must be initialised first).
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

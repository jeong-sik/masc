(** Observation of native executions durably attached to an immutable verifier
    original. No operation in this module dispatches or resumes a model. *)
type reference
val keeper_name : Verifier_review_original.t -> (string, string) result
val session_root : base_path:string -> Verifier_review_original.t -> (string, string) result
(** Persistent private review tree, distinct from the producer and workspace. *)
val capture : original:Verifier_review_original.t -> runtime_id:string -> execution:Types_core.verifier_execution_reference ->
  (Yojson.Safe.t, string) result
val references : original:Verifier_review_original.t -> Lane_addon_request_progress.t ->
  (reference list, string) result

type observation =
  | Awaiting
  | Repair_required of string
  | Cancelled_without_verdict of Task.Anti_rationalization.review_result
      (** Every recorded call ended without a verdict, and at least one was
          cancelled with its effects settled ([Retire]) before it invoked the
          report tool. The result names the cancelled runtimes as
          [retryable_runtimes]: a cancellation passes with time, so a successor
          attempt may review the same original. *)
  | Verdict of Task.Anti_rationalization.review_result

val observe : base_path:string -> original:Verifier_review_original.t ->
  Lane_addon_request_progress.t -> (observation, string) result
(** Validate all recorded call bindings and read their exact root journals.
    Only a terminal success or a settled cancellation with a single admitted,
    successfully settled report invocation may supply a verdict. A failed
    terminal never does. Unknown effects, ambiguous report
    histories and missing historical locators never authorize execution. A
    cancelled call whose effects are settled and that never invoked the report
    tool is [Cancelled_without_verdict], not a repair.
    A live or contended writer without a terminal remains [Awaiting]. Confirmed
    writer loss without a canonical terminal returns [Repair_required], using
    the existing operator-reconciliation path and preserving the original. *)

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
  | No_verdict of (string * Verifier_review_ending.t) list
      (** Every recorded execution has ended with its effects settled, and
          none settled a report invocation. Each execution's runtime and
          ending, in the order the executions were recorded. Whether the
          original is reviewed again is the caller's reading of what the walk
          left; this module only establishes that no verdict was produced. *)
  | Verdict of Task.Anti_rationalization.review_result

val observe : base_path:string -> original:Verifier_review_original.t ->
  Lane_addon_request_progress.t -> (observation, string) result
(** Validate all recorded call bindings and read their exact root journals.
    An execution's ending and its settled report invocations are read apart,
    and the settled report invocations are counted over every recorded
    execution. Exactly one, admitted and settled successfully, supplies the
    verdict whatever ended its execution afterwards: the handler had already
    recorded it. A report invocation that was opened and never admitted did
    not reach its handler and is not counted. Any other settled report
    history, an admitted Tool attempt without a settled result, an
    official-client session and a missing historical locator are
    [Repair_required]; none of them authorizes execution.
    A live or contended writer without a terminal remains [Awaiting]. Confirmed
    writer loss without a canonical terminal is an ending like the others: its
    tree is read as the lost writer last committed it. *)

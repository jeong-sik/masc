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

type no_verdict_cause =
  | No_settled_report
      (** No recorded execution settled a report invocation. A report that
          was requested and never started may remain. *)
  | Answer_format_moved
      (** The original asked for an answer format that is no longer the
          review protocol, so no report its executions settled is taken as a
          verdict. *)

type observation =
  | Awaiting
  | Repair_required of string
  | No_verdict of
      { first : string * Verifier_review_ending.t
      ; later : (string * Verifier_review_ending.t) list
      ; cause : no_verdict_cause
      }
      (** Every recorded execution has ended with its effects settled, and no
          report is read for the reason [cause] names. Each execution's
          runtime and ending, in the order the executions were recorded:
          there is at least one.
          Whether the original is reviewed again is the caller's reading of
          what the walk left; this module only establishes that no verdict
          was produced. *)
  | Verdict of Task.Anti_rationalization.review_result

val observe : base_path:string -> original:Verifier_review_original.t ->
  Lane_addon_request_progress.t -> (observation, string) result
(** Validate all recorded call bindings and read their exact root journals.
    An execution's ending and its report calls are read apart, and the report
    calls are counted over every recorded execution: the settled report
    invocations, and the report calls the recorded provider responses asked
    for. One settled report that is the only one asked for, admitted and
    settled successfully, supplies the verdict whatever ended its execution
    afterwards: the handler had already recorded it. A report that was asked
    for and holds no result never reached its handler, whether or not its
    invocation was opened. With no settled report it leaves the attempt
    without a verdict; beside a settled one it shows the reviewer asked to
    report more than once. Under the current answer format, that, any other
    settled report history (a report
    the pre-execution gate refused is settled without an attempt), an
    admitted Tool attempt without a settled result, an official-client
    session and a missing historical locator are [Repair_required]; none of
    them authorizes execution.
    A live or contended writer without a terminal remains [Awaiting]. Confirmed
    writer loss without a canonical terminal is an ending like the others: its
    tree is read as the lost writer last committed it.
    A report answers the answer format its original asked for. When that
    format is no longer the review protocol, ended executions are [No_verdict]
    with [Answer_format_moved] whatever reports they settled: none is taken as
    a verdict. Each journal's report history is still read, and one that
    cannot be read stays an error. A live writer still makes the attempt
    [Awaiting], and an execution that needs repair or a missing locator still
    makes it [Repair_required]. *)

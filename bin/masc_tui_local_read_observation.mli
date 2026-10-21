(** Facts for one original local source request, never read/effect authority. *)
type source = Local_keepers | Local_work
type intent = Poll | Refresh
type identity =
  { source:source; intent:intent; request_id:int; demand_revision:string
  ; workspace_revision:int; workspace_fingerprint:string option }
type stage = Io | Task_comparison
type failure = Raised | Interrupted
type worker_context = Shared_worker | Inline
type worker_outcome = Body_returned | Body_failed of failure
type caller_outcome = Returned | Caller_failed of failure | Not_started
type comparison = Immediate | Compare
type rejection = Wrong_source | Workspace_withdrawn | Superseded
type admission = Accepted | Accepted_failure | Rejected of rejection
type application = Applied | Apply_failed of failure | Read_failure_applied
type retirement = Replaced | Read_invalidated
type event =
  | Caller_started | Submitted of stage | Worker_entered of stage * worker_context
  | Worker_returned of stage * worker_outcome | Submission_observed of stage * caller_outcome
  | Comparison_decided of comparison | Caller_observed of caller_outcome
  | Ui_admission of admission | Ui_application of application | Retired of retirement
  | Cancellation_requested | Registration_released
type stage_facts = private
  { submitted_ns:int64 option; worker_entered:(int64 * worker_context) option
  ; worker_returned:(int64 * worker_outcome) option; caller_observed:(int64 * caller_outcome) option }
type facts = private
  { requested_ns:int64; caller_started_ns:int64 option; io:stage_facts; comparison:stage_facts
  ; comparison_decided:(int64 * comparison) option; caller_observed:(int64 * caller_outcome) option
  ; ui_admission:(int64 * admission) option; ui_application:(int64 * application) option
  ; retired:(int64 * retirement) option; cancellation_requested_ns:int64 option
  ; registration_released_ns:int64 option }
type t
val create : requested_ns:int64 -> identity -> t
val observe : t -> event -> unit
(** Keep the first actual fact atomically before protected diagnostic emission.
    Emit the changed fact only, joined to the requested identity by capture ID.
    Detailed emission uses the existing routine level; suppressed logging skips
    JSON serialization but retains every in-memory fact and the pending display.
    Missing stages stay absent; sink failures do not decide the original job. *)
val run : t -> read:(unit -> 'a) -> prepare:('a -> 'b) -> 'b
(** Actual shared I/O submission followed by caller-side preparation, with separate
    I/O worker, submission caller and whole-pipeline caller facts. No replay. *)
val compare_tasks : t -> name:string -> (unit -> 'a) -> 'a
(** Actual shared CPU submission for the already chosen Task comparison. *)
val apply : t -> ('a -> unit) -> 'a -> unit
(** Observe UI state application after the caller's original admission; exceptions
    retain their backtraces and are not converted into a successful application. *)
val facts : t -> facts
(** Same-process monotonic first observations, without
    paths, Task text, context or exception detail. Worker body return is not
    executor quiescence; registration release is the workspace registry boundary;
    state application is not paint, usable input or useful Task progress. *)
type pending = Awaiting_start | Io_queued | Io_running | Io_returning | Preparing
  | Comparison_queued | Comparison_running | Comparison_returning | Awaiting_ui
val pending : t -> pending
(** A projection of observed facts only. The caller must separately check that
    the original source still has an active read. No elapsed-time inference. *)

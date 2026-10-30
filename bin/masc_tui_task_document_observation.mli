(** Source-qualified facts, never preparation/admission authority. *)
type source = Work of string | Async of
  { submitted_by:string; request_id:string; keeper_name:string; run_id:string; task_id:string }
type identity =
  { source:source; part:Masc_tui_task_document.part; columns:int; generation:int64
  ; workspace_revision:int; workspace_fingerprint:string option }
type failure = Raised | Interrupted
type worker_context = Shared_worker | Inline
type worker_outcome = Prepared | Worker_failed of failure
type caller_outcome = Returned | Caller_failed of failure | Not_started
type rejection = Reading_withdrawn | Superseded | Source_or_width_changed
type admission = Applied | Applied_failure | Rejected of rejection
type retirement = Replaced | Source_unavailable | Reading_suspended | Workspace_withdrawn | Rejected_owner
type event =
  | Requested | Caller_started | Submit_requested | Worker_entered of worker_context
  | Worker_returned of worker_outcome | Caller_observed of caller_outcome
  | Ui_disposition of admission | Retired of retirement
  | Cancellation_requested | Registration_released
type facts = private
  { requested_ns:int64 option; caller_started_ns:int64 option; submit_requested_ns:int64 option
  ; worker_entered:(int64 * worker_context) option; worker_returned:(int64 * worker_outcome) option
  ; caller_observed:(int64 * caller_outcome) option; ui_disposition:(int64 * admission) option
  ; retired:(int64 * retirement) option; cancellation_requested_ns:int64 option
  ; registration_released_ns:int64 option }
type t
val create : identity -> t
val observe : t -> event -> unit
(** Record the first fact atomically before diagnostic emission. Emission is
    protected observational work; sink failure does not decide the job result.
    Uses the existing Transport log, no new output/configuration surface. *)
val run : t -> name:string -> (unit -> 'a) -> 'a
(** The actual shared CPU submission path, with worker/caller facts. Original
    exceptions and cancellation propagate with their backtraces, without replay. *)
val facts : t -> facts
val snapshot_json : t -> Yojson.Safe.t
(** Missing stages stay null. Same-process monotonic times, source identities
    and dimensions only; no Task text, context, paths or exception detail.
    Worker return is not executor quiescence; registration release is the
    workspace registry boundary; UI admission is not input, paint or success. *)

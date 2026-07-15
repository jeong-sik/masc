(** Durable store for scheduled internal automation requests.

    This layer records schedule intent and generic execution attempts. It
    deliberately does not authorize or execute payload effects. *)

type rejected_schedule_row =
  { ordinal : int
  ; raw : Yojson.Safe.t
  ; error : Schedule_domain.schedule_request_decode_error
  }
(** A schedule row rejected by the versioned recurrence decoder. Its raw JSON
    is preserved across writes, but it never enters eligibility or dispatch. *)

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; rejected_schedules : rejected_schedule_row list
  ; executions : Schedule_domain.execution_record list
  }

type store_error =
  | Schedule_already_exists
  | Schedule_not_found
  | Invalid_initial_status of string
  | Invalid_status_transition of string
  | Schedule_not_due_candidate
  | Schedule_not_running
  | Recurrence_evaluation_failed of Schedule_domain.recurrence_evaluation_error
  | Persistence_failed of string
  | Corrupt_ledger of
      { primary_err : string
      ; recovery_err : string option
      }
      (** RFC-0234: returned by mutating functions when the on-disk ledger is
          present but neither it nor its [.last-good] recovery file parses. The
          mutation is refused so the corrupt bytes are NOT overwritten. *)

type running_recovery_reason =
  | Retryable_dispatch_failure of string
  | Recurrence_evaluation_failure of Schedule_domain.recurrence_evaluation_error
  | Interrupted_by_process_restart

val running_recovery_reason_to_string : running_recovery_reason -> string

val store_error_to_string : store_error -> string

type read_error =
  | Corrupt_read_ledger of
      { primary_err : string
      ; recovery_err : string option
      }
      (** Read-only access found a present-but-unparseable ledger. *)

val read_error_to_string : read_error -> string

(** Outcome of loading the durable ledger. [Fresh] is a legitimately absent file
    (empty store); [Corrupt] is a present-but-unparseable file that must not be
    silently defaulted or overwritten. *)
type load_outcome =
  | Loaded of state
  | Fresh
  | Corrupt of
      { primary_err : string
      ; recovery_err : string option
      }

(** Raised by [read_state]/[list_schedules]/[get_schedule] on a corrupt ledger.
    Read paths have no [result] channel, so they fail loud instead of returning
    an empty list. Mutating paths report [Corrupt_ledger] instead. *)
exception
  Corrupt_ledger_exn of
    { primary_err : string
    ; recovery_err : string option
    }

val schedules_path : Workspace_utils.config -> string

(** Total load that distinguishes a fresh (absent) ledger from a corrupt
    (present-but-unparseable) one. Performs no writes. *)
val load : Workspace_utils.config -> load_outcome

(** Read-only snapshot. Returns the empty [default_state] for a [Fresh] store and
    raises {!Corrupt_ledger_exn} for a corrupt one. Never writes to disk. *)
val read_state : Workspace_utils.config -> state

(** Result-returning read-only snapshot. Returns the empty [default_state] for a
    [Fresh] store and [Error (Corrupt_read_ledger _)] for a corrupt one. Never
    writes to disk. *)
val read_state_result : Workspace_utils.config -> (state, read_error) result

val default_state : unit -> state
val state_to_yojson : state -> Yojson.Safe.t
val state_of_yojson : Yojson.Safe.t -> (state, string) result

val list_schedules : Workspace_utils.config -> Schedule_domain.schedule_request list
val get_schedule :
  Workspace_utils.config -> schedule_id:string -> Schedule_domain.schedule_request option
val executions_for_schedule :
  state -> schedule_id:string -> Schedule_domain.execution_record list
val last_execution_for_schedule :
  state -> schedule_id:string -> Schedule_domain.execution_record option

val insert_request :
  Workspace_utils.config ->
  Schedule_domain.schedule_request ->
  (Schedule_domain.schedule_request, store_error) result

val cancel_request :
  Workspace_utils.config ->
  schedule_id:string ->
  (Schedule_domain.schedule_request, store_error) result

val update_request :
  Workspace_utils.config ->
  schedule_id:string ->
  due_at:float ->
  expires_at:float option ->
  payload:Schedule_domain.payload ->
  (Schedule_domain.schedule_request, store_error) result
(** Replaces [due_at], [expires_at], and [payload] of a scheduled request.
    Returns [Invalid_status_transition] for due, terminal, or [Running]
    requests. *)

val refresh_due :
  Workspace_utils.config ->
  now:float ->
  (state * int, store_error) result
(** Marks stored [Scheduled] requests as [Due] when [due_at <= now]. The
    integer is the number of requests changed. *)

val reschedule_due_recurring :
  Workspace_utils.config ->
  now:float ->
  schedule_ids:string list ->
  (state * int, store_error) result
(** Advances matching recurring [Due] requests back to [Scheduled] after their
    generic due signal has been durably recorded. One-shot requests are left
    [Due] for a future consumer/terminal transition. Recurrence evaluation
    failures abort the mutation explicitly. *)

val start_due_candidate :
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  (Schedule_domain.schedule_request, store_error) result
(** Atomically transitions a due candidate to [Running] and records a
    generic execution attempt. *)

val complete_running :
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  ?detail:Yojson.Safe.t ->
  unit ->
  (Schedule_domain.schedule_request, store_error) result
(** Completes a [Running] request. One-shot requests become [Succeeded];
    recurring requests advance to the next [Scheduled] occurrence. The matching
    execution attempt is marked [succeeded]. A recurrence evaluation failure
    leaves both records [Running] and is returned explicitly for runner recovery. *)

val fail_running :
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  error:string ->
  (Schedule_domain.schedule_request, store_error) result
(** Marks a [Running] request and its matching execution attempt [Failed]. *)

val retry_running :
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  reason:running_recovery_reason ->
  (Schedule_domain.schedule_request, store_error) result
(** Finishes the current execution attempt as [Failed] while returning only the
    matching schedule to [Due]. Its due time and payload remain unchanged, so
    the next runner tick retries the same occurrence identity. *)

val recover_running_on_startup :
  Workspace_utils.config ->
  now:float ->
  (state * int, store_error) result
(** Atomically returns every persisted [Running] schedule to [Due] and finishes
    each matching execution attempt as [Failed]. Intended for a one-time runner
    startup recovery before any new dispatch can be active. The recovery reason
    is fixed to [Interrupted_by_process_restart]. *)

val fail_due_candidate :
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  error:string ->
  (Schedule_domain.schedule_request, store_error) result
(** Atomically marks a [Due] request [Failed] and records the failed
    execution attempt. This is used when a runner-side consumer rejects the
    payload before work starts, so the schedule does not remain due forever. *)

val due_execution_candidates :
  state -> Schedule_domain.schedule_request list
(** Returns all due requests. Authorization of dispatched effects belongs to
    the payload consumer. *)

val prune_completed :
  Workspace_utils.config ->
  (state * int, store_error) result
(** Deletes all terminal (succeeded, failed, cancelled, expired) schedule
    requests and their associated execution records. *)

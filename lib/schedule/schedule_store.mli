(** Durable store for scheduled internal automation requests.

    This layer records schedule intent and generic execution attempts. It
    deliberately does not authorize or execute payload effects. *)

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; executions : Schedule_domain.execution_record list
  }

type store_error =
  | Schedule_already_exists
  | Schedule_not_found
  | Invalid_initial_status of string
  | Invalid_status_transition of string
  | Schedule_not_due_candidate
  | Schedule_not_running
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
  | Interrupted_by_process_restart

type dispatched_occurrence_outcome =
  | Dispatched_occurrence_succeeded
  | Dispatched_occurrence_failed of string

type dispatched_occurrence_settlement =
  { execution_id : string
  ; schedule_id : string
  ; due_at : float
  ; payload_digest : string
  ; outcome : dispatched_occurrence_outcome
  }

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

val execution_for_occurrence :
  state ->
  schedule_id:string ->
  due_at:float ->
  payload_digest:string ->
  Schedule_domain.execution_record option
(** Exact occurrence lookup. This is the correlation boundary used by
    asynchronous consumers; schedule id alone is insufficient for recurring
    work because multiple dispatched executions may coexist. *)

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
    [Due] for a future consumer/terminal transition. *)

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
    execution attempt is marked [succeeded]. *)

val accept_running :
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  ?detail:Yojson.Safe.t ->
  unit ->
  (Schedule_domain.schedule_request, store_error) result
(** Records that a consumer durably accepted asynchronous work. Recurring
    requests advance to their next [Scheduled] occurrence; one-shot requests
    remain [Running]. The matching execution remains unfinished with status
    [Execution_dispatched] until a correlated work-completion path settles it. *)

val complete_dispatched_occurrence :
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  due_at:float ->
  payload_digest:string ->
  unit ->
  (Schedule_domain.schedule_request, store_error) result
(** Marks every execution for one exact running/dispatched occurrence
    succeeded. Idempotent when that occurrence is already succeeded. A one-shot
    request becomes [Succeeded]; an already-advanced recurring request keeps
    its next due row. The original dispatch receipt in the execution detail is
    preserved. *)

val fail_dispatched_occurrence :
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  due_at:float ->
  payload_digest:string ->
  error:string ->
  (Schedule_domain.schedule_request, store_error) result
(** Marks every execution for one exact running/dispatched occurrence failed.
    Idempotent when that occurrence is already failed. A recurring schedule
    continues at its already-computed next occurrence. *)

val settle_dispatched_occurrences :
  Workspace_utils.config ->
  now:float ->
  dispatched_occurrence_settlement list ->
  (unit, store_error) result
(** Validate and settle an exact execution batch under one schedule-ledger lock
    and one durable write. Every execution id must agree with the supplied
    occurrence identity. Any invalid settlement leaves the entire batch
    unchanged. *)

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
    each exact current occurrence's execution attempt as [Failed]. Exact
    occurrence identity, rather than wall-clock ordering, distinguishes a newly
    interrupted retry from an older dispatched recurrence. Intended for a
    one-time runner startup recovery before any new dispatch can be active. The
    recovery reason is fixed to [Interrupted_by_process_restart]. *)

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

val unsettled_dispatched_occurrences :
  state -> Schedule_domain.execution_record list
(** Every [Execution_dispatched] execution.

    These are occurrences a consumer durably accepted and has not settled. The
    store cannot decide whether the consumer still owns one: that requires
    decoding the consumer-owned dispatch detail to learn where it went, which
    is consumer territory. Orphan executions are returned rather than silently
    omitted; a later terminal write will surface [Schedule_not_found]. *)

val prune_completed :
  Workspace_utils.config ->
  (state * int, store_error) result
(** Deletes terminal (succeeded, failed, cancelled, expired) schedule requests
    and their associated execution records.

    A terminal request is retained while any of its executions is still
    unsettled ([Execution_running] or [Execution_dispatched]). Terminal here
    describes the request's intent, not the work: a recurring request advances
    past an occurrence at [accept_running] and can be cancelled afterwards while
    that occurrence is still outstanding. The execution row is then the only
    durable record of work a consumer accepted, and both
    [complete_dispatched_occurrence] and [fail_dispatched_occurrence] return
    [Schedule_not_found] without the request row — so pruning the pair would
    both erase the evidence and make the occurrence unsettleable. *)

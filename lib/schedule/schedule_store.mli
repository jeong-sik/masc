(** Durable store for scheduled internal automation requests.

    This layer records schedule intent and generic wake attempts. It
    deliberately does not authorize or execute payload effects. *)

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; wakes : Schedule_domain.wake_record list
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
      (** RFC-0234: returned by mutating functions when at least one of the
          ledger and its [.last-good] recovery file exists and no state can be
          parsed from either. [recovery_err] is [None] when no recovery file
          exists. The mutation is refused so the surviving bytes are NOT
          overwritten. *)

type running_recovery_reason =
  | Retryable_dispatch_failure of string
  | Interrupted_by_process_restart

val running_recovery_reason_to_string : running_recovery_reason -> string

val store_error_to_string : store_error -> string

type read_error =
  | Corrupt_read_ledger of
      { primary_err : string
      ; recovery_err : string option
      }
      (** Read-only access found ledger bytes on disk that yield no state. *)

val read_error_to_string : read_error -> string

(** Raised by [read_state]/[get_schedule] when ledger bytes exist but yield no
    state. Read paths have no [result] channel, so they fail loud instead of
    returning an empty list. Mutating paths report [Corrupt_ledger] instead. *)
exception
  Corrupt_ledger_exn of
    { primary_err : string
    ; recovery_err : string option
    }

(** Read-only snapshot. Returns an empty state only when neither the ledger nor
    its [.last-good] recovery file exists; when the ledger is gone but the
    recovery file parses, the recovered state is returned and the substitution is
    logged. Raises {!Corrupt_ledger_exn} when ledger bytes exist but yield no
    state. Never writes to disk. *)
val read_state : Workspace_utils.config -> state

(** Result-returning read-only snapshot. Returns an empty state only when neither
    the ledger nor its [.last-good] recovery file exists, the recovered state
    when the ledger is gone but the recovery file parses, and
    [Error (Corrupt_read_ledger _)] when ledger bytes exist but yield no state.
    Never writes to disk. *)
val read_state_result : Workspace_utils.config -> (state, read_error) result

val state_of_yojson : Yojson.Safe.t -> (state, string) result

val get_schedule :
  Workspace_utils.config -> schedule_id:string -> Schedule_domain.schedule_request option
val last_wake_for_schedule_instance :
  state ->
  schedule_instance_id:string ->
  schedule_id:string ->
  Schedule_domain.wake_record option

val wakes_for_schedule_instance :
  state ->
  schedule_instance_id:string ->
  schedule_id:string ->
  Schedule_domain.wake_record list
(** Every retained wake of one schedule instance, newest first. Bounded by the
    store's own sweep, not by this call: in-flight wakes all survive and
    terminal ones keep {!terminal_wakes_retained_per_schedule} per schedule.
    [last_wake_for_schedule_instance] is the head of this list. *)

val terminal_wakes_retained_per_schedule : int
(** Terminal wakes the sweep keeps per schedule_id, newest first. A reader of
    a wake list needs this number to know the list is a ceiling rather than a
    complete history. *)

val insert_request :
  Workspace_utils.config ->
  Schedule_domain.schedule_request ->
  (Schedule_domain.schedule_request, store_error) result

val update_request :
  Workspace_utils.config ->
  Schedule_domain.schedule_request ->
  (Schedule_domain.schedule_request, store_error) result
(** Atomically replaces an existing [Scheduled] or [Due] request. The caller
    supplies a newly validated request with the same stable [schedule_id] and
    a fresh [schedule_instance_id], so wakes from the previous definition do
    not become evidence for the replacement. Running and terminal requests
    are immutable. *)

val cancel_request :
  Workspace_utils.config ->
  schedule_id:string ->
  (Schedule_domain.schedule_request, store_error) result

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
  ?started_at:float ->
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  (Schedule_domain.schedule_request, store_error) result
(** Atomically transitions a due candidate to [Running] and records a
    generic wake attempt. [now] is the tick that found the candidate due;
    [started_at] (default [now]) stamps the wake with the moment the attempt
    began, so a reader can measure the attempt rather than the tick. *)

val accept_running :
  ?finished_at:float ->
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  ?detail:Yojson.Safe.t ->
  unit ->
  (Schedule_domain.schedule_request, store_error) result
(** Records that a consumer durably accepted asynchronous work. Recurring
    requests advance to their next [Scheduled] occurrence after [now]; one-shot
    requests become [Succeeded]. The matching wake completes immediately as a
    wake-delivery receipt stamped [finished_at] (default [now]); Keeper turn
    results live in the Keeper ledger. *)

val fail_running :
  ?finished_at:float ->
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  error:string ->
  (Schedule_domain.schedule_request, store_error) result
(** Marks a [Running] request and its matching wake attempt [Failed]. The
    wake is stamped [finished_at] (default [now]). *)

val retry_running :
  ?finished_at:float ->
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  reason:running_recovery_reason ->
  (Schedule_domain.schedule_request, store_error) result
(** Finishes the current wake attempt as [Failed] (stamped [finished_at],
    default [now]) while returning only the matching schedule to [Due]. Its
    due time and payload remain unchanged, so the next runner tick retries the
    same occurrence identity. *)

val recover_running_on_startup :
  Workspace_utils.config ->
  now:float ->
  (state * int, store_error) result
(** Atomically returns every persisted [Running] schedule to [Due] and finishes
    each exact current occurrence's wake attempt as [Failed]. Exact
    occurrence identity distinguishes an interrupted dispatch attempt. Intended
    for one-time runner startup recovery before any new dispatch can be active.
    The recovery reason is fixed to [Interrupted_by_process_restart]. *)

val fail_due_candidate :
  ?attempted_at:float ->
  Workspace_utils.config ->
  now:float ->
  schedule_id:string ->
  error:string ->
  (Schedule_domain.schedule_request, store_error) result
(** Atomically marks a [Due] request [Failed] and records the failed
    wake attempt, started and finished at [attempted_at] (default [now]).
    This is used when a runner-side consumer rejects the payload before work
    starts, so the schedule does not remain due forever. *)

val due_wake_candidates :
  state -> Schedule_domain.schedule_request list
(** Returns all due requests. Authorization of downstream effects belongs to
    the payload consumer. *)

val cancel_matching :
  Workspace_utils.config ->
  should_cancel:(Schedule_domain.schedule_request -> bool) ->
  (unit, store_error) result
(** Atomically cancels every matching [Scheduled] or [Due] request. A matching
    [Running] request is rejected because wake delivery is still in progress. *)

val prune_completed :
  Workspace_utils.config ->
  (state * int, store_error) result
(** Deletes terminal schedule requests and their wake-delivery records. *)

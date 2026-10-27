(** Durable store for scheduled internal automation requests.

    This layer records schedule intent and generic wake attempts. It
    deliberately does not authorize or execute payload effects. *)

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; wakes : Schedule_domain.wake_record list
  ; notes : Schedule_domain.schedule_note list
  }

(** The caller-requested transitions that only a [Scheduled] or [Due]
    request accepts. *)
type attempted_transition =
  | Modify_schedule
  | Cancel_schedule
  | Cancel_for_consumer_retirement
      (** {!cancel_matching}: the schedules of a consumer that is being
          retired, which a wake still in delivery holds back. *)

val attempted_transition_to_string : attempted_transition -> string

type mutation_authority =
  | Operator_authority
  | Named_authority of
      { name : string
      ; wake_keeper_name : Schedule_domain.schedule_request -> string option
      }
(** Constructed from the trusted dispatch caller, never call arguments.
    A named caller changes rows it scheduled or rows that wake it. The
    consumer supplies its canonical, read-only wake-target projection because
    this library treats payloads as opaque. [None] means no Keeper target.
    Both current-row and replacement ownership are checked under the ledger
    mutation lock; an earlier observation grants no authority. *)

type store_error =
  | Schedule_already_exists
  | Schedule_not_found
  | Not_schedule_owner of
      { schedule_id : string
      ; caller : string
      ; scheduled_by_id : string
      ; wake_target : string option
      }
  | Invalid_initial_status of string
  | Transition_refused of
      { schedule_id : string
      ; current : Schedule_domain.schedule_status
      ; attempted : attempted_transition
      ; last_wake : Schedule_domain.wake_record option
      }
      (** The request is [Running] or terminal. [current] is the status the
          store read under its lock, and [last_wake] is that instance's
          newest wake, so a refused caller sees what already happened
          without a second read. *)
  | Changed_due_already_past of
      { schedule_id : string
      ; stored_due_at : float
      ; due_at : float
      ; now : float
      }
      (** {!update_request} refused a replacement whose due time differs from
          the stored one at whole-second resolution and is before [now], the
          updating call's clock cut to the whole second. *)
  | Interval_below_runner_tick of
      { schedule_id : string
      ; below : Schedule_domain.interval_below_runner_tick
      }
      (** {!insert_request} or {!update_request} refused an [Interval] shorter
          than the schedule runner tick. See
          {!Schedule_domain.interval_fires_as_declared}. *)
  | Running_wake_absent of { schedule_id : string }
      (** A [Running] request has no wake record at all to settle or
          recover. *)
  | Running_wake_settled of
      { schedule_id : string
      ; wake : Schedule_domain.wake_record
      }
      (** A [Running] request whose newest wake already succeeded or failed,
          so there is no running wake to settle or recover. *)
  | Schedule_not_due_candidate
  | Running_attempt_superseded of { schedule_id : string }
      (** The authoritative ledger proves this capability no longer denotes
          the current attempt or its already applied verdict. No write occurs. *)
  | Running_attempt_unavailable of { schedule_id : string; reason : string }
      (** Authority could not be established, including a non-authoritative
          read, unidentified/contradictory wake, or another workspace/backend.
          This is an error, never evidence of supersession. *)
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

type failure_scope = Occurrence_failure | Schedule_failure

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

val with_ledger_lock : Workspace_utils.config -> (unit -> 'a) -> 'a
(** Serialize a composed durable transfer through its target projection with
    schedule mutation. Acquire any ordered Keeper intake fences before this
    lock and durable queue locks inside it. Never call this from a store
    mutation callback, which already owns the ledger lock. *)

type recovery_cause = Primary_missing | Primary_unusable

type read_source =
  | Uninitialized
  | Primary_ledger
  | Recovery_mirror of recovery_cause

val read_state_observed :
  Workspace_utils.config -> ((state * read_source), read_error) result
(** The same read as [read_state_result], retaining whether the primary or
    recovery mirror supplied it. A recovered state's counts are observations
    of that mirror, not authoritative totals or bounds on the missing primary.
    [Primary_unusable] includes read, JSON and ledger-schema failures; raw
    diagnostics remain in the store's existing warning/error channel. *)

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
  runner_tick_sec:float ->
  Schedule_domain.schedule_request ->
  (Schedule_domain.schedule_request, store_error) result

type timing_update = Replace_timing | Keep_timing | Keep_recurrence
(** [Keep_timing] reads the current due time, recurrence and expiry under the
    mutation lock. A content editor cannot restore a stale timing snapshot.
    An expiry on the replacement request replaces the stored one; an absent
    expiry keeps it. [Keep_recurrence] replaces the due time and expiry while
    retaining the latest recurrence under the mutation lock: the caller
    supplied a due input but omitted the recurrence kind. Both
    [Replace_timing] and [Keep_recurrence] can remove an expiry. *)

val update_request :
  Workspace_utils.config ->
  authority:mutation_authority ->
  now:float ->
  runner_tick_sec:float ->
  ?timing_update:timing_update ->
  Schedule_domain.schedule_request ->
  (Schedule_domain.schedule_request, store_error) result
(** Atomically replaces an existing [Scheduled] or [Due] request. The caller
    supplies a newly validated request with the same stable [schedule_id] and
    a fresh [schedule_instance_id], so wakes from the previous definition do
    not become evidence for the replacement. Running and terminal requests
    are immutable. [now] is the updating call's clock: a due time that
    changes and lands before the current whole second is
    [Changed_due_already_past]; the stored due time sent back unchanged is
    accepted whatever the clock says. [timing_update] defaults to
    [Replace_timing]; [Keep_timing] retains the latest stored time, recurrence
    and expiry. [Keep_recurrence] retains only the latest recurrence, while
    replacing due time and expiry. The current row and its replacement must both belong to
    [authority] before any write. Replacement ownership uses the current
    row's scheduler, and the stored requester and scheduler are preserved. *)

val cancel_request :
  Workspace_utils.config ->
  authority:mutation_authority ->
  schedule_id:string ->
  cancellation:Schedule_domain.cancellation ->
  withdraw_queued_wakes:
    (Schedule_domain.schedule_request ->
     Schedule_domain.cancellation ->
     (unit, string) result) ->
  (Schedule_domain.schedule_request, store_error) result
(** Marks a [Scheduled] or [Due] request [Cancelled], stores [cancellation]
    on it, and settles its in-flight wake rows. Before the write, under the
    ledger lock, it calls [withdraw_queued_wakes] with the stored request so
    the caller removes the wakes already queued for it; this library has no
    view of those queues. A withdrawal [Error] is [Persistence_failed] and
    no schedule ledger change is written; earlier queue withdrawals remain
    durable. [Running] and terminal requests are
    [Transition_refused]. Current-row ownership is checked before the
    withdrawal callback or any write; an unauthorized request has no effects. *)

val refresh_due :
  Workspace_utils.config ->
  now:float ->
  retention_days:int ->
  (state * int, store_error) result
(** Marks stored [Scheduled] requests as [Due] when [due_at <= now]. The
    integer is the number of requests changed.

    The same pass forgets finished schedules whose wake finished more than
    [retention_days] ago and about which nothing has been written since, with
    the wakes of those schedules; their notes stay. A schedule that never ran
    records no finishing time and is left to {!prune_completed}. At most a
    bounded number are forgotten per pass, they are not counted in the returned
    integer, and the count is logged.

    [retention_days] has no default here: how long to keep a finished schedule
    is the caller's policy, and a window this pass silently invented would be
    one an operator cannot change. *)

val terminal_schedule_retention_days : int
(** The window a caller with no policy of its own should pass as
    [retention_days]: how long a finished schedule stays in the ledger after
    the wake that ended it. *)

val reschedule_due_recurring :
  Workspace_utils.config ->
  now:float ->
  schedule_ids:string list ->
  (state * int, store_error) result
(** Advances matching recurring [Due] requests back to [Scheduled] after their
    generic due signal has been durably recorded. One-shot requests are left
    [Due] for a future consumer/terminal transition. *)

type running_attempt
(** Opaque authority for one persisted identified wake in its originating
    workspace/backend. Obtained only from a committed start. All settlement
    methods revalidate this authority against the primary ledger under its
    mutation lock. Recovery mirrors and unidentified historical wakes cannot
    authorize settlement. Repeating the same typed verdict preserves its
    original receipt; supersession and unavailable authority remain distinct
    errors. A replay must preserve the original [now] recurrence anchor. *)

type started_dispatch = private
  { request : Schedule_domain.schedule_request
  ; attempt : running_attempt
  }

val start_due_candidate :
  ?started_at:float ->
  Workspace_utils.config ->
  now:float ->
  candidate:Schedule_domain.schedule_request ->
  (started_dispatch, store_error) result
(** Atomically transitions a due candidate to [Running] and records a
    generic wake attempt. [now] is the tick that found the candidate due;
    [started_at] (default [now]) stamps the wake with the moment the attempt
    began, so a reader can measure the attempt rather than the tick. The
    candidate's instance, due time and payload must still match under the lock. *)

val accept_running :
  ?finished_at:float ->
  Workspace_utils.config ->
  now:float ->
  attempt:running_attempt ->
  ?detail:Yojson.Safe.t ->
  unit ->
  (Schedule_domain.schedule_request, store_error) result
(** Records that a consumer durably accepted asynchronous work. Recurring
    requests advance to their next [Scheduled] occurrence after [now]; one-shot
    requests become [Succeeded]. The matching wake completes immediately as a
    wake-delivery receipt stamped [finished_at] (default [now]); Keeper turn
    results live in the Keeper ledger. Repeated calls for the same verdict must
    retain the original [now], even after later recurrence boundaries pass. *)

val fail_running :
  ?finished_at:float ->
  Workspace_utils.config ->
  now:float ->
  attempt:running_attempt ->
  failure_scope:failure_scope ->
  error:string ->
  (Schedule_domain.schedule_request, store_error) result
(** Records the matching wake attempt as [Wake_failed], stamped [finished_at]
    (default [now]). [Schedule_failure] ends the request as [Failed].
    [Occurrence_failure] advances to the next [Scheduled] occurrence after
    [now], or ends as [Failed] when no future occurrence exists. The tick
    [now], not the attempt's finish time, anchors recurrence advancement. A
    delayed retry must retain that original [now], rather than recompute the
    next occurrence using its later wall-clock observation. *)

val retry_running :
  ?finished_at:float ->
  Workspace_utils.config ->
  now:float ->
  attempt:running_attempt ->
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
  candidate:Schedule_domain.schedule_request ->
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
(** Atomically cancels every matching [Scheduled] or [Due] request, for a
    consumer that is being retired. A matching [Running] request refuses the
    whole call with [Transition_refused] and [Cancel_for_consumer_retirement],
    because wake delivery is still in progress. *)

val prune_completed :
  Workspace_utils.config ->
  (state * int, store_error) result
(** Deletes terminal schedule requests and their wake-delivery records. *)

val append_note :
  Workspace_utils.config ->
  schedule_id:string ->
  author_id:string ->
  author_kind:Schedule_domain.actor_kind ->
  body:string ->
  now:float ->
  (Schedule_domain.schedule_note * int, store_error) result
(** Appends a note to one schedule's note history and returns it with the new
    note count for that schedule_id. The ledger load, note identity/count
    derivation and publication run under the schedule-file lock. An unreadable
    ledger returns [Corrupt_ledger]; an absent schedule returns
    [Schedule_not_found].

    Notes are keyed by the stable
    [schedule_id], not the per-instance id, so a definition replacement
    (masc_schedule_update) does not orphan the prose that explains it. Notes
    are append-only: no edit, no removal. *)

val notes_for_schedule :
  state -> schedule_id:string -> Schedule_domain.schedule_note list
(** Every retained note of one schedule_id, oldest first. Notes survive
    terminal state transitions: they are history, not state. *)

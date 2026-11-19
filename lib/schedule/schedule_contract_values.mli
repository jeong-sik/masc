(** Typed wire vocabulary shared by the schedule domain and its tool schemas. *)

type decode_error =
  { field : string
  ; rejected : string
  ; accepted : string list
  }

val decode_error_to_string : decode_error -> string

type actor_kind =
  | Human_operator
  | Automated_actor
  | System

val actor_kind_to_string : actor_kind -> string
val actor_kind_of_string : string -> (actor_kind, decode_error) result
val actor_kind_strings : string list

type schedule_status =
  | Scheduled
  | Due
  | Running
  | Succeeded
  | Failed
  | Cancelled
  | Expired

val schedule_statuses : schedule_status list
val schedule_status_to_string : schedule_status -> string
val schedule_status_of_string : string -> (schedule_status, decode_error) result
val schedule_status_strings : string list

(** What a schedule listing's [status] selects: one status, or
    [Status_active], every status that is not terminal by
    [Schedule_domain.is_terminal]. *)
type status_selector =
  | Status_exact of schedule_status
  | Status_active

val status_selector_to_string : status_selector -> string
val status_selector_of_string : string -> (status_selector, decode_error) result
val status_selector_strings : string list

type schedule_source =
  | Operator_request
  | Automated_request
  | System_request

val schedule_source_to_string : schedule_source -> string
val schedule_source_of_string : string -> (schedule_source, decode_error) result
val schedule_source_strings : string list

type recurrence_kind =
  | One_shot
  | Interval
  | Daily
  | Cron

val recurrence_kind_to_string : recurrence_kind -> string
val recurrence_kind_of_string : string -> (recurrence_kind, decode_error) result
val recurrence_kind_strings : string list

type wake_status =
  | Wake_running
  | Wake_succeeded
  | Wake_failed

val wake_statuses : wake_status list
val wake_status_to_string : wake_status -> string
val wake_status_of_string : string -> (wake_status, decode_error) result
val wake_status_strings : string list

(** [keeper_queue_evidence.projection_status] of a dashboard schedule row:
    what the woken Keeper's durable event queue holds for the wake. *)
type queue_projection_status =
  | Queue_matched_pending  (** The wake is still in the owner's queue. *)
  | Queue_retained_terminal_wake
      (** Still queued, but the schedule was cancelled: a withdrawn leftover. *)
  | Queue_withdrawn_at_cancel
      (** Absent from the queue, and the schedule was cancelled. *)
  | Queue_not_found  (** Absent from the queue. *)
  | Queue_matched_terminal_completed  (** The queue recorded completion. *)
  | Queue_matched_terminal_cancelled  (** The queue recorded cancellation. *)
  | Queue_terminal_projection_pending
      (** A terminal transition is written but not yet projected. *)
  | Queue_transfer_projection_pending
      (** The wake is moving to another owner. *)
  | Queue_evidence_invalid
      (** The durable source does not match this occurrence. *)
  | Queue_read_error  (** The queue could not be read. *)
  | Queue_unrecognized_receipt
      (** The dispatch receipt cannot name the queued occurrence. *)

val queue_projection_status_to_string : queue_projection_status -> string

val queue_projection_status_of_string
  :  string
  -> (queue_projection_status, decode_error) result

val queue_projection_status_strings : string list

(** [keeper_reaction_evidence.projection_status] of a dashboard schedule row:
    the furthest step the woken Keeper's reaction ledger recorded. *)
type reaction_projection_status =
  | Reaction_conflicting_terminal_evidence
      (** Both an ack and a cancellation were recorded. *)
  | Reaction_matched_terminal_cancelled
  | Reaction_matched_consumed_ack
  | Reaction_matched_turn_finished
  | Reaction_matched_turn_started
  | Reaction_matched_stimulus  (** Only the stimulus arrival was recorded. *)
  | Reaction_not_found  (** The ledger has no row for the stimulus. *)
  | Reaction_quarantined  (** A matching row failed to decode. *)
  | Reaction_read_error
  | Reaction_missing_stimulus_id
  | Reaction_invalid_stimulus_id
  | Reaction_unrecognized_receipt

val reaction_projection_status_to_string : reaction_projection_status -> string

val reaction_projection_status_of_string
  :  string
  -> (reaction_projection_status, decode_error) result

val reaction_projection_status_strings : string list

(** The schedule runner's own [status], as [/health] reports it under
    [schedule_runner] and the schedule list reports it beside its rows. The
    runner re-reads what it holds only on a tick that succeeds, so a reader of
    a hold needs this word to know whether that hold is still being checked. *)
type runner_status =
  | Runner_not_started  (** No tick has run in this process yet. *)
  | Runner_running  (** A tick is in flight. *)
  | Runner_stale
      (** The newest tick finished longer ago than the server's threshold. *)
  | Runner_degraded
      (** The newest tick failed, or it dispatched or woke with failures. *)
  | Runner_ok  (** The newest tick succeeded, recently and without failures. *)

val runner_status_to_string : runner_status -> string
val runner_status_of_string : string -> (runner_status, decode_error) result

(** Selector for whose schedules a listing reads: the caller on either side of
    a schedule, the Keeper a schedule wakes, the actor that scheduled it, or
    every row. *)
type owner_kind =
  | Owner_self
  | Owner_wake_target
  | Owner_scheduled_by
  | Owner_all

val owner_kind_to_string : owner_kind -> string
val owner_kind_of_string : string -> (owner_kind, decode_error) result
val owner_kind_strings : string list

(** Why a schedule tool refused a call: the [error_kind] field of its result.
    Each kind names a different next step for the caller. *)
type refusal_kind =
  | Refusal_due_already_past
      (** The due time is before the current whole second. *)
  | Refusal_transition_refused
      (** The row is running or terminal; the result names its status. *)
  | Refusal_due_inputs_conflict
      (** More than one of due_at_unix, due_at_iso and due_in_sec. *)
  | Refusal_due_input_missing
      (** No due input, and the recurrence cannot derive one. *)
  | Refusal_caller_unidentified
      (** The call needs the caller's name and the endpoint does not know it. *)
  | Refusal_actor_mismatch
      (** An actor id argument names someone other than the caller. *)
  | Refusal_argument_out_of_range
      (** An integer argument outside its declared minimum and maximum. *)
  | Refusal_cursor_mismatch
      (** A cursor used with filters other than the listing that issued it. *)
  | Refusal_not_schedule_owner
      (** A named caller asked to update or cancel a schedule it did not
          make and that does not wake it. *)

val refusal_kind_to_string : refusal_kind -> string
val refusal_kind_of_string : string -> (refusal_kind, decode_error) result
val refusal_kind_strings : string list

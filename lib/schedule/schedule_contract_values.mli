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

val wake_status_to_string : wake_status -> string
val wake_status_of_string : string -> (wake_status, decode_error) result
val wake_status_strings : string list

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

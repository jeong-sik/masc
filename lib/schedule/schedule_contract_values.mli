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

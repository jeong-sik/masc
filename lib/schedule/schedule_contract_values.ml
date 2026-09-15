type decode_error =
  { field : string
  ; rejected : string
  ; accepted : string list
  }

let decode_error_to_string error =
  Printf.sprintf
    "unknown %s: %s; accepted: %s"
    error.field
    error.rejected
    (String.concat ", " error.accepted)
;;

let decode_wire_value ~field ~to_string values wire_value =
  match List.find_opt (fun value -> String.equal (to_string value) wire_value) values with
  | Some value -> Ok value
  | None -> Error { field; rejected = wire_value; accepted = List.map to_string values }
;;

type actor_kind =
  | Human_operator
  | Automated_actor
  | System
[@@deriving enumerate]

let actor_kinds = all_of_actor_kind

let actor_kind_to_string = function
  | Human_operator -> "human_operator"
  | Automated_actor -> "automated_actor"
  | System -> "system"
;;

let actor_kind_of_string =
  decode_wire_value ~field:"actor_kind" ~to_string:actor_kind_to_string actor_kinds
;;

let actor_kind_strings = List.map actor_kind_to_string actor_kinds

type schedule_status =
  | Scheduled
  | Due
  | Running
  | Succeeded
  | Failed
  | Cancelled
  | Expired
[@@deriving enumerate]

let schedule_statuses = all_of_schedule_status

let schedule_status_to_string = function
  | Scheduled -> "scheduled"
  | Due -> "due"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Cancelled -> "cancelled"
  | Expired -> "expired"
;;

let schedule_status_of_string =
  decode_wire_value
    ~field:"schedule_status"
    ~to_string:schedule_status_to_string
    schedule_statuses
;;

let schedule_status_strings = List.map schedule_status_to_string schedule_statuses

type schedule_source =
  | Operator_request
  | Automated_request
  | System_request
[@@deriving enumerate]

let schedule_sources = all_of_schedule_source

let schedule_source_to_string = function
  | Operator_request -> "operator_request"
  | Automated_request -> "automated_request"
  | System_request -> "system_request"
;;

let schedule_source_of_string =
  decode_wire_value
    ~field:"schedule_source"
    ~to_string:schedule_source_to_string
    schedule_sources
;;

let schedule_source_strings = List.map schedule_source_to_string schedule_sources

type recurrence_kind =
  | One_shot
  | Interval
  | Daily
  | Cron
[@@deriving enumerate]

let recurrence_kinds = all_of_recurrence_kind

let recurrence_kind_to_string = function
  | One_shot -> "one_shot"
  | Interval -> "interval"
  | Daily -> "daily"
  | Cron -> "cron"
;;

let recurrence_kind_of_string =
  decode_wire_value
    ~field:"recurrence_kind"
    ~to_string:recurrence_kind_to_string
    recurrence_kinds
;;

let recurrence_kind_strings = List.map recurrence_kind_to_string recurrence_kinds

type wake_status =
  | Wake_running
  | Wake_succeeded
  | Wake_failed
[@@deriving enumerate]

let wake_statuses = all_of_wake_status

let wake_status_to_string = function
  | Wake_running -> "running"
  | Wake_succeeded -> "succeeded"
  | Wake_failed -> "failed"
;;

let wake_status_of_string =
  decode_wire_value ~field:"wake_status" ~to_string:wake_status_to_string wake_statuses
;;

let wake_status_strings = List.map wake_status_to_string wake_statuses

(* Whose schedules [masc_schedule_list] reads. A schedule names two actors: the
   one that created it ([scheduled_by.id]) and the Keeper it wakes (the wake
   payload's [keeper_name]). They agree on most rows and are still different
   facts, so each is its own selector. [Owner_self] is the caller on either
   side; [Owner_all] is every row, asked for by name rather than by omission. *)
type owner_kind =
  | Owner_self
  | Owner_wake_target
  | Owner_scheduled_by
  | Owner_all
[@@deriving enumerate]

let owner_kinds = all_of_owner_kind

let owner_kind_to_string = function
  | Owner_self -> "self"
  | Owner_wake_target -> "wake_target"
  | Owner_scheduled_by -> "scheduled_by"
  | Owner_all -> "all"
;;

let owner_kind_of_string =
  decode_wire_value ~field:"owner" ~to_string:owner_kind_to_string owner_kinds
;;

let owner_kind_strings = List.map owner_kind_to_string owner_kinds

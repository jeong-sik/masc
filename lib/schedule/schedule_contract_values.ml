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

(* What [masc_schedule_list]'s [status] selects: one status, or every status a
   schedule can still act in. [Status_active] is a name rather than three
   statuses spelled by the caller, so a caller asking "what is still live"
   keeps no copy of which statuses those are. The tool reads that from
   [Schedule_domain.is_terminal]; this module only names the choice, because
   the domain depends on it and not the other way round. *)
type status_selector =
  | Status_exact of schedule_status
  | Status_active
[@@deriving enumerate]

let status_selectors = all_of_status_selector

let status_selector_to_string = function
  | Status_exact status -> schedule_status_to_string status
  | Status_active -> "active"
;;

let status_selector_of_string =
  decode_wire_value ~field:"status" ~to_string:status_selector_to_string status_selectors
;;

let status_selector_strings = List.map status_selector_to_string status_selectors

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

type runner_status =
  | Runner_not_started
  | Runner_running
  | Runner_stale
  | Runner_degraded
  | Runner_ok
[@@deriving enumerate]

let runner_status_to_string = function
  | Runner_not_started -> "not_started"
  | Runner_running -> "running"
  | Runner_stale -> "stale"
  | Runner_degraded -> "degraded"
  | Runner_ok -> "ok"
;;

let runner_status_of_string =
  decode_wire_value
    ~field:"runner_status"
    ~to_string:runner_status_to_string
    all_of_runner_status
;;

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

(* Why a schedule tool refused a call, as the [error_kind] field its result
   carries. A caller branches on this rather than on the sentence next to it,
   and each kind names a different next step: pick a later time, read the
   status the row is already in, name yourself, send exactly one due input,
   stay inside the declared range, start a listing again without the
   cursor, or leave a schedule that belongs to another caller alone. A
   refusal without a kind here is one whose sentence is the whole answer. *)
type refusal_kind =
  | Refusal_due_already_past
  | Refusal_transition_refused
  | Refusal_due_inputs_conflict
  | Refusal_due_input_missing
  | Refusal_caller_unidentified
  | Refusal_actor_mismatch
  | Refusal_argument_out_of_range
  | Refusal_cursor_mismatch
  | Refusal_not_schedule_owner
[@@deriving enumerate]

let refusal_kinds = all_of_refusal_kind

let refusal_kind_to_string = function
  | Refusal_due_already_past -> "due_already_past"
  | Refusal_transition_refused -> "transition_refused"
  | Refusal_due_inputs_conflict -> "due_inputs_conflict"
  | Refusal_due_input_missing -> "due_input_missing"
  | Refusal_caller_unidentified -> "caller_unidentified"
  | Refusal_actor_mismatch -> "actor_mismatch"
  | Refusal_argument_out_of_range -> "argument_out_of_range"
  | Refusal_cursor_mismatch -> "cursor_mismatch"
  | Refusal_not_schedule_owner -> "not_schedule_owner"
;;

let refusal_kind_of_string =
  decode_wire_value ~field:"error_kind" ~to_string:refusal_kind_to_string refusal_kinds
;;

let refusal_kind_strings = List.map refusal_kind_to_string refusal_kinds

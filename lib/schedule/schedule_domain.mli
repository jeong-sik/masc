(** Pure domain model for scheduled internal automation.

    A schedule request records intent only. Side-effecting execution is gated
    by a later execution grant from a separate human principal. *)

type actor_kind =
  | Human_operator
  | Automated_actor
  | System

type actor =
  { id : string
  ; kind : actor_kind
  ; display_name : string option
  }

type risk_class =
  | Reminder_only
  | Read_only
  | Workspace_write
  | External_write
  | Destructive
  | Cost_bearing

type schedule_status =
  | Pending_approval
  | Scheduled
  | Due
  | Running
  | Succeeded
  | Failed
  | Rejected
  | Cancelled
  | Expired

val all_schedule_statuses : schedule_status list

type schedule_source =
  | Operator_request
  | Automated_request
  | System_request

(** Recurrence contract.

    [Daily.timezone] is a fixed-offset selector, not full civil-timezone
    support. It accepts UTC aliases, Asia/Seoul/KST as +09:00 aliases, and
    explicit fixed offsets such as [+09:00] or [UTC+09:00]. It never consults
    host local time or DST rules.

    [Cron.expression] is a standard 5-field expression
    [minute hour day-of-month month day-of-week]. It supports wildcards,
    comma lists, numeric ranges, and step syntax such as [*/15] and [1-5/2].
    Day-of-week accepts [0] or [7] for Sunday. When both day-of-month and
    day-of-week are restricted, matching follows Vixie cron semantics: either
    field may match. *)
type recurrence =
  | One_shot
  | Interval of { interval_sec : int }
  | Daily of
      { hour : int
      ; minute : int
      ; second : int
      ; timezone : string
      }
  | Cron of
      { expression : string
      ; timezone : string
      }

(** Opaque consumer payload.

    The schedule domain does not interpret payload kind or body fields, but it
    does require a typed envelope so producers cannot persist an ambiguous raw
    string/null/list as future intent. Serialized shape:
    [{ kind: string; schema_version: int; body: object }]. *)
type payload

type schedule_request =
  { schedule_id : string
  ; requested_by : actor
  ; scheduled_by : actor
  ; requested_at : float
  ; due_at : float
  ; expires_at : float option
  ; payload : payload
  ; risk_class : risk_class
  ; approval_required : bool
  ; status : schedule_status
  ; source : schedule_source
  ; recurrence : recurrence
  }

type execution_decision =
  | Approve
  | Reject of string

type execution_evidence =
  { schedule_id : string
  ; payload_digest : string
  ; due_at : float
  ; risk_class : risk_class
  }

type execution_grant =
  { grant_id : string
  ; schedule_id : string
  ; approved_by : actor
  ; approved_at : float
  ; decision : execution_decision
  ; evidence : execution_evidence
  }

type execution_status =
  | Execution_running
  | Execution_succeeded
  | Execution_failed

type execution_record =
  { execution_id : string
  ; schedule_id : string
  ; started_at : float
  ; finished_at : float option
  ; due_at : float
  ; payload_digest : string
  ; status : execution_status
  ; detail : Yojson.Safe.t option
  ; error : string option
  }

type grant_error =
  | Grant_schedule_id_mismatch
  | Approver_not_human
  | Approver_is_requester
  | Approver_is_scheduler
  | Schedule_terminal
  | Schedule_not_pending_approval
  | Evidence_schedule_id_mismatch
  | Evidence_payload_digest_mismatch
  | Evidence_due_at_mismatch
  | Evidence_risk_class_mismatch

val create_request :
  schedule_id:string ->
  requested_by:actor ->
  scheduled_by:actor ->
  requested_at:float ->
  due_at:float ->
  ?expires_at:float ->
  payload:Yojson.Safe.t ->
  risk_class:risk_class ->
  approval_required:bool ->
  source:schedule_source ->
  ?recurrence:recurrence ->
  unit ->
  (schedule_request, string) result

val is_terminal : schedule_status -> bool
val is_side_effecting : risk_class -> bool
val requires_separate_human_grant : schedule_request -> bool
val is_recurring : recurrence -> bool
val validate_recurrence : recurrence -> (recurrence, string) result
val first_due_after : now:float -> recurrence -> float option
(** Compute the first due time for calendar recurrences that do not need an
    explicit [due_at] anchor. Returns [None] for [One_shot] and [Interval]. *)

val next_due_after : now:float -> schedule_request -> float option
val reschedule_after_due_signal : now:float -> schedule_request -> schedule_request option

val payload_of_yojson : Yojson.Safe.t -> (payload, string) result
val payload_to_yojson : payload -> Yojson.Safe.t
val payload_digest : payload -> string
val evidence_of_request : schedule_request -> execution_evidence

val create_execution_grant :
  grant_id:string ->
  approved_by:actor ->
  approved_at:float ->
  decision:execution_decision ->
  schedule_request ->
  execution_grant

val validate_execution_grant :
  schedule_request -> execution_grant -> (unit, grant_error) result

val apply_execution_grant :
  schedule_request -> execution_grant -> (schedule_request, grant_error) result

val mark_due : now:float -> schedule_request -> schedule_request
(** Observes time for active requests. [Pending_approval], [Scheduled], and
    [Due] requests whose [expires_at <= now] become [Expired]; otherwise
    [Scheduled] requests whose [due_at <= now] become [Due]. *)

val actor_kind_to_string : actor_kind -> string
val actor_kind_of_string : string -> (actor_kind, string) result
val risk_class_to_string : risk_class -> string
val risk_class_of_string : string -> (risk_class, string) result
val schedule_status_to_string : schedule_status -> string
val schedule_status_of_string : string -> (schedule_status, string) result
val schedule_source_to_string : schedule_source -> string
val schedule_source_of_string : string -> (schedule_source, string) result
val recurrence_kind_to_string : recurrence -> string
val recurrence_summary : recurrence -> string
(** Stable, human-readable recurrence summary for dashboard and keeper tool
    outputs. This is presentation-only; schedule eligibility still uses the
    typed [recurrence] value. *)
val execution_status_to_string : execution_status -> string
val execution_status_of_string : string -> (execution_status, string) result
val grant_error_to_string : grant_error -> string

val actor_to_yojson : actor -> Yojson.Safe.t
val actor_of_yojson : Yojson.Safe.t -> (actor, string) result
val recurrence_to_yojson : recurrence -> Yojson.Safe.t
val recurrence_of_yojson : Yojson.Safe.t -> (recurrence, string) result
val execution_evidence_to_yojson : execution_evidence -> Yojson.Safe.t
val execution_evidence_of_yojson :
  Yojson.Safe.t -> (execution_evidence, string) result
val execution_grant_to_yojson : execution_grant -> Yojson.Safe.t
val execution_grant_of_yojson : Yojson.Safe.t -> (execution_grant, string) result
val execution_record_to_yojson : execution_record -> Yojson.Safe.t
val execution_record_of_yojson :
  Yojson.Safe.t -> (execution_record, string) result
val schedule_request_to_yojson : schedule_request -> Yojson.Safe.t
val schedule_request_of_yojson : Yojson.Safe.t -> (schedule_request, string) result

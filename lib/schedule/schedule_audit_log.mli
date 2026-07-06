(** Append-only lifecycle audit log for scheduled automation requests.

    The schedule store remains the snapshot/serving ledger. This module records
    successful state transitions as JSONL rows so operators can replay why a
    schedule moved between states without diffing snapshots. *)

type action =
  | Request_created
  | Grant_approved
  | Grant_rejected
  | Request_cancelled
  | Request_marked_due
  | Request_expired
  | Request_rescheduled
  | Execution_started
  | Execution_succeeded
  | Execution_failed
  | Due_candidate_failed

type event =
  { schema_version : int
  ; event_id : string
  ; recorded_at : float
  ; action : action
  ; schedule_id : string
  ; state_version : int
  ; previous_status : Schedule_domain.schedule_status option
  ; current_status : Schedule_domain.schedule_status
  ; payload_digest : string
  ; due_at : float
  ; actor : Schedule_domain.actor option
  ; detail : Yojson.Safe.t option
  }

type projection_coverage =
  | Events_recorded
  | No_lifecycle_events
  | Read_error

type backfill_policy = Not_synthesized_from_schedule_snapshot

val path : Workspace_utils.config -> string
val action_to_string : action -> string
val action_of_string : string -> (action, string) result
val projection_coverage_to_string : projection_coverage -> string
val backfill_policy_to_string : backfill_policy -> string

val make :
  recorded_at:float ->
  state_version:int ->
  action:action ->
  ?previous:Schedule_domain.schedule_request ->
  current:Schedule_domain.schedule_request ->
  ?actor:Schedule_domain.actor ->
  ?detail:Yojson.Safe.t ->
  unit ->
  event

val event_to_yojson : event -> Yojson.Safe.t
val event_of_yojson : Yojson.Safe.t -> (event, string) result

val default_projection_limit : int
val recent_for_schedule : event list -> schedule_id:string -> limit:int -> event list
val projection_for_schedule :
  (event list, string) result -> schedule_id:string -> limit:int -> (event list, string) result

val projection_to_yojson : limit:int -> (event list, string) result -> Yojson.Safe.t
val append : Workspace_utils.config -> event -> (unit, string) result
val append_many : Workspace_utils.config -> event list -> (unit, string) result
val read_all : Workspace_utils.config -> (event list, string) result
val read_recent : Workspace_utils.config -> limit:int -> (event list, string) result

val read_recent_for_schedule :
  Workspace_utils.config -> schedule_id:string -> limit:int -> (event list, string) result

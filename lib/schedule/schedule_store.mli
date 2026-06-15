(** Durable store for scheduled internal automation requests.

    This layer records intent and execution grants. It deliberately does not
    execute work. Runner/tool wiring must consume due candidates later. *)

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; grants : Schedule_domain.execution_grant list
  }

type store_error =
  | Schedule_already_exists
  | Schedule_not_found
  | Grant_already_recorded
  | Invalid_initial_status of string
  | Invalid_status_transition of string
  | Grant_validation_failed of Schedule_domain.grant_error

val store_error_to_string : store_error -> string

val schedules_path : Workspace_utils.config -> string
val read_state : Workspace_utils.config -> state

val default_state : unit -> state
val state_to_yojson : state -> Yojson.Safe.t
val state_of_yojson : Yojson.Safe.t -> (state, string) result

val list_schedules : Workspace_utils.config -> Schedule_domain.schedule_request list
val get_schedule :
  Workspace_utils.config -> schedule_id:string -> Schedule_domain.schedule_request option

val insert_request :
  Workspace_utils.config ->
  Schedule_domain.schedule_request ->
  (Schedule_domain.schedule_request, store_error) result

val record_grant :
  Workspace_utils.config ->
  Schedule_domain.execution_grant ->
  (Schedule_domain.schedule_request, store_error) result

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

val due_execution_candidates :
  state -> Schedule_domain.schedule_request list
(** Returns only due requests that are no longer pending approval. *)

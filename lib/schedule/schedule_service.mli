(** User-facing service boundary for scheduled internal automation.

    This module creates durable schedule records. It does not run due work,
    authorize payload effects, or interact with consumer lifecycle state. *)

type service_error =
  | Invalid_request of string
  | Store_error of Schedule_store.store_error

val service_error_to_string : service_error -> string

val create :
  Workspace_utils.config ->
  ?schedule_id:string ->
  ?requested_at:float ->
  ?expires_at:float ->
  requested_by:Schedule_domain.actor ->
  scheduled_by:Schedule_domain.actor ->
  due_at:float ->
  payload:Yojson.Safe.t ->
  source:Schedule_domain.schedule_source ->
  ?recurrence:Schedule_domain.recurrence ->
  unit ->
  (Schedule_domain.schedule_request, service_error) result

val list :
  Workspace_utils.config ->
  ?status:Schedule_domain.schedule_status ->
  unit ->
  Schedule_domain.schedule_request list

val get :
  Workspace_utils.config ->
  schedule_id:string ->
  Schedule_domain.schedule_request option

val cancel :
  Workspace_utils.config ->
  schedule_id:string ->
  (Schedule_domain.schedule_request, service_error) result

val update :
  Workspace_utils.config ->
  schedule_id:string ->
  due_at:float ->
  expires_at:float option ->
  payload:Schedule_domain.payload ->
  (Schedule_domain.schedule_request, service_error) result

val due_candidates :
  Workspace_utils.config ->
  now:float ->
  (Schedule_domain.schedule_request list, service_error) result
(** Refreshes due state and returns visible execution candidates. No execution
    is performed here. *)

val prune :
  Workspace_utils.config ->
  (Schedule_store.state * int, service_error) result
(** Deletes all terminal schedules and returns the new state and the number of pruned items. *)

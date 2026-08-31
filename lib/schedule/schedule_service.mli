(** User-facing service boundary for scheduled internal automation.

    This module creates durable schedule records. It does not run due work,
    authorize payload effects, or interact with consumer lifecycle state. *)

type service_error =
  | Invalid_request of string
  | Store_error of Schedule_store.store_error
  | Creation_rejected of string

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

val update :
  Workspace_utils.config ->
  schedule_id:string ->
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
(** Replaces one active definition under its stable [schedule_id]. The new
    request receives a fresh instance id; the store refuses running and
    terminal schedules. *)

val cancel :
  Workspace_utils.config ->
  schedule_id:string ->
  (Schedule_domain.schedule_request, service_error) result

val prune :
  Workspace_utils.config ->
  (Schedule_store.state * int, service_error) result
(** Deletes all terminal schedules and returns the new state and the number of pruned items. *)

(** User-facing service boundary for scheduled internal automation.

    This module creates durable schedule records. It does not run due work,
    authorize payload effects, or interact with consumer lifecycle state. *)

type service_error =
  | Invalid_request of string
  | Store_error of Schedule_store.store_error
  | Creation_rejected of string
  | Due_already_past of
      { due_at : float
      ; now : float
      }
      (** [create] refused a first due time before [now], the creating call's
          clock cut to the whole second. A stored past due would be marked
          [Due] by the next refresh and fire at once. *)

val service_error_to_string : service_error -> string

val create :
  Workspace_utils.config ->
  now:float ->
  runner_tick_sec:float ->
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
(** Stores a new [Scheduled] request. [now] is the clock of the call that is
    creating it, not [requested_at], which a caller may set. [due_at] is
    compared with [now] cut to the whole second, because an RFC 3339 due time
    arrives truncated to whole seconds: a due time in the current second is
    accepted, and an earlier one is [Due_already_past]. *)

val update :
  Workspace_utils.config ->
  now:float ->
  runner_tick_sec:float ->
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
    terminal schedules. [now] is the updating call's clock: the store refuses
    a due time that changes and lands before the current whole second
    ({!Schedule_store.Changed_due_already_past}), and accepts the stored due
    time sent back unchanged. *)

val cancel :
  Workspace_utils.config ->
  schedule_id:string ->
  (Schedule_domain.schedule_request, service_error) result

val prune :
  Workspace_utils.config ->
  (Schedule_store.state * int, service_error) result
(** Deletes all terminal schedules and returns the new state and the number of pruned items. *)

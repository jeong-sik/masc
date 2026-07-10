(** User-facing service boundary for scheduled internal automation.

    This module creates and approves durable schedule records. It does not run
    due work and does not interact with consumer lifecycle state. *)

type service_error =
  | Invalid_request of string
  | Store_error of Schedule_store.store_error

val service_error_to_string : service_error -> string

val create :
  Workspace_utils.config ->
  ?schedule_id:string ->
  ?requested_at:float ->
  ?expires_at:float ->
  ?approval_required:bool ->
  requested_by:Schedule_domain.actor ->
  scheduled_by:Schedule_domain.actor ->
  due_at:float ->
  payload:Yojson.Safe.t ->
  risk_class:Schedule_domain.risk_class ->
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

(** Record an approval grant. [scope] defaults to
    [Schedule_domain.Grant_occurrence] (this due occurrence only);
    [Grant_standing] keeps covering future occurrences while the
    schedule's payload digest and risk class stay unchanged and the grant has
    not been invalidated by an update or explicit revocation. *)
val approve :
  Workspace_utils.config ->
  ?grant_id:string ->
  ?approved_at:float ->
  ?scope:Schedule_domain.grant_scope ->
  schedule_id:string ->
  approved_by:Schedule_domain.actor ->
  unit ->
  (Schedule_domain.schedule_request, service_error) result

val reject :
  Workspace_utils.config ->
  ?grant_id:string ->
  ?approved_at:float ->
  schedule_id:string ->
  approved_by:Schedule_domain.actor ->
  reason:string ->
  unit ->
  (Schedule_domain.schedule_request, service_error) result

val cancel :
  Workspace_utils.config ->
  schedule_id:string ->
  (Schedule_domain.schedule_request, service_error) result

val revoke_standing :
  Workspace_utils.config ->
  ?revoked_at:float ->
  schedule_id:string ->
  revoked_by:Schedule_domain.actor ->
  unit ->
  (Schedule_domain.schedule_request * int, service_error) result
(** Revokes all active standing grants for the schedule while preserving their
    approval and revocation evidence in the durable ledger. *)

val update :
  Workspace_utils.config ->
  ?updated_at:float ->
  schedule_id:string ->
  due_at:float ->
  expires_at:float option ->
  payload:Schedule_domain.payload ->
  updated_by:Schedule_domain.actor ->
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

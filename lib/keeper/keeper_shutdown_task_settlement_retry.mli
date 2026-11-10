(** Explicit recovery of one retained task-settlement refusal. This module
    prepares the original shutdown operation; it never releases Tasks, purges
    artifacts or changes the original actor/intent. Transport authentication
    and the operator's audit reason belong to the CanAdmin HTTP boundary. *)

type error =
  | Invalid_request of string
  | Store_error of Keeper_shutdown_store.error
  | Ineligible_operation
  | Owner_unavailable of Keeper_owner_registry.lookup_error
  | Owner_observation_failed of Keeper_owner.error
  | Owner_stopping
  | Owner_metadata_absent
  | Owner_trace_changed
  | Owner_turn_present
  | Registry_lane_present
  | Lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Admission_mismatch
  | Backlog_unavailable of string
  | Backlog_revision_conflict of { expected : int; actual : int }
  | Corrupt_sibling of Keeper_shutdown_store.corrupt_record
  | Conflicting_sibling of Keeper_shutdown_types.Operation_id.t
  | Unordered_sibling of Keeper_shutdown_types.Operation_id.t
  | New_owned_tasks of string list
  | Recorded_task_changed of string

type preview =
  { operation : Keeper_shutdown_types.t
  ; backlog_version : int
  ; receipted_task_ids : Keeper_id.Task_id.t list
  }

val error_to_string : error -> string

val preview :
  config:Workspace.config -> keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  (preview, error) result
(** Read-only eligibility observation, not a reservation or write authority.
    Commit repeats every check, including the sibling scan under store locks. *)

val prepare :
  config:Workspace.config -> keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  expected_revision:int -> expected_backlog_version:int ->
  (Keeper_shutdown_types.t, error) result
(** Lock order: intake -> lifecycle key -> backlog -> shutdown inventory ->
    exact operation. Requires the existing owner and intake fences to name
    this exact operation, unchanged trace, no live child/lane, no newer or
    unreadable sibling, and canonical original Task ownership or exact release
    receipts. Only prepares [Finalizing_tasks]; scheduling/completion are
    separate observations. Repeating an old revision is a conflict. *)

module For_testing : sig
  val prepare :
    on_guards_acquired:(unit -> unit) ->
    config:Workspace.config -> keeper_name:string ->
    operation_id:Keeper_shutdown_types.Operation_id.t ->
    expected_revision:int -> expected_backlog_version:int ->
    (Keeper_shutdown_types.t, error) result
  (** Call-scoped race observation after intake/lifecycle guards, before the
      canonical backlog and exact operation are read. *)
end

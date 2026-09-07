(** Explicit operator-owned acknowledgement of an absent retained owner.
    This does not remove metadata, settle work, or erase shutdown evidence.
    Transport callers must supply the authenticated CanAdmin actor. *)
type error =
  | Invalid_request of string
  | Store_error of Keeper_shutdown_store.error
  | Ineligible_operation
  | Outstanding_recorded_tasks of string list
  | Outstanding_tasks of string list
  | Outstanding_chat_operations of Keeper_chat_operation.Operation_id.t list
  | Outstanding_semantic_executions of Keeper_execution_scope_id.t list
  | Chat_operations_unavailable of Keeper_chat_operation_store.error
  | Backlog_unavailable of string
  | Backlog_revision_conflict of { expected : int; actual : int }
  | Owner_present
  | Owner_unavailable of Keeper_owner_registry.lookup_error
  | Registry_lane_present
  | Path_present of string
  | Path_unreadable of string * Unix.error
  | Corrupt_sibling of Keeper_shutdown_store.corrupt_record
  | Unfinished_sibling of Keeper_shutdown_types.Operation_id.t
  | Admission_owned_by_other of Keeper_shutdown_types.Operation_id.t

val error_to_string : error -> string

val acknowledge_absent_owner :
  config:Workspace.config ->
  keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  expected_revision:int ->
  expected_backlog_version:int ->
  actor:string ->
  reason:string ->
  (Keeper_shutdown_store.absence_acknowledgement_result, error) result
(** Lock order: intake -> lifecycle key -> backlog -> shutdown inventory ->
    exact operation. All creation paths take intake and/or lifecycle key.
    Authoritative checks and operation CAS run inside these same guards.
    Idempotent replay does not check or alter a newer owner; it only releases
    a process-local intake reservation still owned by this exact operation. *)

module For_testing : sig
  val acknowledge_absent_owner :
    on_guards_acquired:(unit -> unit) ->
    config:Workspace.config ->
    keeper_name:string ->
    operation_id:Keeper_shutdown_types.Operation_id.t ->
    expected_revision:int ->
    expected_backlog_version:int ->
    actor:string ->
    reason:string ->
    (Keeper_shutdown_store.absence_acknowledgement_result, error) result
  (** Same guarded transaction, with a call-scoped observer after acquiring
      intake and lifecycle guards. No process-global test hook is installed. *)
end

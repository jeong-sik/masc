(** Non-blocking lifecycle orchestration for durable Keeper shutdown. *)

type submit_error =
  | Prepare_error of Keeper_shutdown_prepare_join.error
  | Existing_operation_load_error of Keeper_shutdown_store.error
  | Worker_start_error of worker_start_error

and worker_start_error =
  | Worker_supervisor_unavailable
  | Worker_supervisor_stopping of exn
  | Worker_fork_failed of exn

type restored_inventory =
  { operations : Keeper_shutdown_types.t list
  ; blocked_keeper_names : string list
  ; corrupt_records : Keeper_shutdown_store.corrupt_record list
  }

val submit_error_to_string : submit_error -> string

(** Restore admission from owner-addressable durable inventory. Corrupt
    payloads fence their path owner and remain explicit in [corrupt_records];
    valid operations for unrelated Keepers remain recoverable. *)
val restore_inventory_admission :
  config:Workspace.config ->
  Keeper_shutdown_store.inventory_entry list ->
  (restored_inventory, string) result

(** Fence admission and persist the operation synchronously, then fork lane
    join/finalization on the process-lifetime Keeper supervisor switch. The
    returned operation id is durable before this function returns. *)
val submit :
  config:Workspace.config ->
  entry:Keeper_registry.registry_entry ->
  request:Keeper_shutdown_prepare_join.request ->
  (Keeper_shutdown_types.t, submit_error) result

(** Recover operations left by an earlier server process. Must run before
    Keeper autoboot so a stopped Keeper cannot acquire a replacement lane
    ahead of settlement. Returns one explicit result per durable operation. *)
val recover_at_boot :
  config:Workspace.config ->
  (Keeper_shutdown_types.t, string) result list

(** Recover one durable operation without consulting global inventory. This
    lets bootstrap isolate every Keeper in its own process-lifetime fiber. *)
val recover_operation :
  config:Workspace.config ->
  Keeper_shutdown_types.t ->
  (Keeper_shutdown_types.t, string) result

module For_testing : sig
  val persist_unhandled_failure :
    now:(unit -> string) ->
    config:Workspace.config ->
    Keeper_shutdown_types.t ->
    exn ->
    unit
end

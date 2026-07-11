(** Non-blocking lifecycle orchestration for durable Keeper shutdown. *)

type submit_error =
  | Prepare_error of Keeper_shutdown_prepare_join.error
  | Existing_operation_load_error of Keeper_shutdown_store.error

val submit_error_to_string : submit_error -> string

(** Fence admission and persist the operation synchronously, then fork lane
    join/finalization on [sw]. The returned operation id is durable before
    this function returns. *)
val submit :
  sw:Eio.Switch.t ->
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

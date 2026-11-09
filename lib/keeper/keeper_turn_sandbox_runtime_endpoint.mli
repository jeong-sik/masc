(** The endpoint of a guest that is up: the admission and observation of an
    Apple endpoint, the endpoint of a running guest from a turn runtime or from
    the keeper alone (an attached reader never starts or prepares a guest), the
    helpers that run a callback with an Apple endpoint, the reason a guest is
    not running, and the in-memory record of whether this process prepared the
    work root of a guest.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_record

type apple_endpoint_admission =
  | Diagnostic_read
  | Existing_execution
  | Prepared_execution

type apple_endpoint_observation =
  | Apple_snapshot_only
  | Apple_running_guest of { timeout_sec : float; admission : apple_endpoint_admission }

val apple_endpoint_of_snapshot_owned :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  scope:Keeper_microvm_lifecycle.keeper_scope ->
  config:Workspace_utils_backend_setup.config ->
  meta:keeper_meta ->
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  container_root:string ->
  uid:int ->
  gid:int ->
  container_name:string ->
  observation:apple_endpoint_observation ->
  (Keeper_sandbox_remote.t * string, string) result

val microvm_remote_endpoint_of_running :
  t -> container_name:string -> (Keeper_sandbox_remote.t, string) result

val microvm_remote_endpoint :
  ?timeout_sec:float -> t -> (Keeper_sandbox_remote.t, string) result

val microvm_attached_endpoint :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:keeper_meta ->
  unit ->
  (Keeper_sandbox_remote.t, string) result

val with_apple_snapshot_endpoint :
  config:Workspace.config -> meta:keeper_meta ->
  (revision:string -> Keeper_sandbox_remote.t -> ('a, string) result) ->
  ('a, string) result

val with_apple_attached_endpoint :
  ?timeout_sec:float -> config:Workspace.config -> meta:keeper_meta ->
  (revision:string -> Keeper_sandbox_remote.t -> ('a, string) result) ->
  ('a, string) result

val microvm_guest_absence_reason :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:keeper_meta ->
  unit ->
  string option

val is_microvm_guest_booted :
  config:Workspace.config ->
  meta:keeper_meta ->
  unit ->
  bool

val forget_microvm_guest_booted :
  config:Workspace.config ->
  meta:keeper_meta ->
  unit ->
  unit

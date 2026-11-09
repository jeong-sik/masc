(** How the runtime names, asks about and stops the container or guest of a
    turn: whether a runtime is a microvm and which backend it declares, the
    Docker exec prefix and the refusal of a microvm guest, whether a container
    exists or runs, the state probe of a microvm guest, what a failed exec
    leads to, the guest name and the egress proxy port bound for it, the
    binding of a registered identity snapshot, and the stop and delete of a
    guest.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_record

val is_microvm : t -> bool

val microvm_backend_of_meta :
  keeper_meta ->
  (Keeper_microvm_backend.t, string) result

val microvm_backend_of :
  t ->
  (Keeper_microvm_backend.t, string) result

val exec_prefix :
  t ->
  container_cwd:string -> stdin:bool -> string list

val docker_exec_only :
  t -> (unit, string) result

val inspect_container_exists :
  ?timeout_sec:float -> string -> (unit, string) result

val probe_microvm_container_state :
  ?timeout_sec:float ->
  backend:Keeper_microvm_backend.t ->
  string -> (Keeper_sandbox_runtime.docker_container_state, string) result

val inspect_container_running :
  ?timeout_sec:float -> string -> (unit, string) result

type failed_exec_recovery =
  | Preserve_failed_exec
  | Restart_failed_exec
  | Failed_exec_state_probe_error of string

val failed_exec_recovery :
  ?timeout_sec:float ->
  t -> failed_exec_recovery

val failed_exec_state_probe_error :
  status:Unix.process_status -> output:string -> string -> string

val microvm_container_name :
  config:Workspace_utils_backend_setup.config ->
  keeper_name:string ->
  network_mode:Keeper_types_profile_sandbox.network_mode -> string

val bound_egress_proxy_port :
  t -> int option

val keeper_vm_name : t -> string

val bind_registered_microvm_identity :
  t ->
  string ->
  process_github_identity_snapshot
  option

val stop_and_delete_microvm_container :
  ?timeout_sec:float ->
  backend:Keeper_microvm_backend.t -> string -> (unit, string) result

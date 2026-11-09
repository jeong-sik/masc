(** The argv a keeper's guest is started, entered and stopped with: the boot
    argv of each runtime, the label that names the runtime, the guest
    constraints a runtime cannot express and the refusal that names them, the
    exec argv with its request environment, and the stop and delete argv.

    [Keeper_sandbox_microvm] includes this module. *)

open Keeper_sandbox_microvm_network

val microvm_backend_label_key : string

type constraint_refusal =
  { guest_constraint : Keeper_microvm_backend.guest_constraint
  ; reason : string
  }

val constraint_refusals_message :
  Keeper_microvm_backend.t -> constraint_refusal list -> string

val turn_start_argv_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  label_args:string list ->
  uid:int ->
  gid:int ->
  guest_size:Keeper_microvm_guest_size.t ->
  network_args:string list ->
  mount_args:string list ->
  image:string ->
  constraints:Keeper_microvm_backend.guest_constraint list ->
  (string list, constraint_refusal list) result

type apple_boot_failure =
  | Apple_invalid_boot_plan of Keeper_microvm_boot_plan.invalid_plan list
  | Apple_network_unavailable of string
  | Apple_constraints_unexpressible of constraint_refusal list

val apple_turn_start_argv :
  container_name:string -> plan:Keeper_microvm_boot_plan.t ->
  lifecycle_labels:(string * string) list -> dns:string option ->
  policy_proxy:policy_proxy option -> (string list, apple_boot_failure) result

val exec_argv_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  uid:int ->
  gid:int ->
  container_cwd:string ->
  stdin:bool ->
  command_argv:string list ->
  string list

val request_environment : shim_config_path:string -> (string * string) list

val shim_exec_prefix_for :
  ?stdin:bool ->
  Keeper_microvm_backend.t ->
  container_name:string ->
  uid:int ->
  gid:int ->
  remote_root:string ->
  shim_config_path:string ->
  (string list, string) result

val stop_argv_for :
  Keeper_microvm_backend.t -> container_name:string -> string list

val delete_force_argv_for :
  Keeper_microvm_backend.t -> container_name:string -> string list

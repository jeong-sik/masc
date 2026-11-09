(** The checkouts of a keeper's work volume and their build output: the scan
    for checkouts, the scripts and argv batches that link each build directory
    onto the build volume, the recreation of that volume, and the probes of the
    work root (its mkdir, whether the volume is mounted, whether it is
    writable).

    [Keeper_sandbox_microvm] includes this module. *)

open Keeper_sandbox_microvm_base

val recreate_apple_build_volume :
  volume_name:string ->
  size:string ->
  timeout_sec:float -> ([> `Already_present | `Created ], string) result

val build_scan_argv_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  keeper_work_root:string -> uid:int -> gid:int -> string list

val build_link_warning : build_link_plan -> string option

val build_argv_values_budget_bytes : int

val build_link_apply_requests_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  keeper_work_root:string ->
  uid:int -> gid:int -> actions:(string * string) list -> string list list

val build_target_mkdir_requests : container_name:string -> targets:string list -> string list list

val work_volume_search_argv_for :
  Keeper_microvm_backend.t -> container_name:string -> string list option

val keeper_work_root_mkdir_argv_for :
  Keeper_microvm_backend.t -> container_name:string -> keeper_name:string -> string list

val work_volume_mounted_probe_argv_for :
  Keeper_microvm_backend.t -> container_name:string -> string list

type work_volume_mount_probe =
  | Work_volume_mounted
  | Work_volume_not_mounted
  | Work_volume_probe_unverified of
      { status : Unix.process_status
      ; stdout : string
      ; stderr : string
      }

val work_volume_mount_probe_of_result :
  status:Unix.process_status ->
  stdout:string -> stderr:string -> work_volume_mount_probe

val keeper_work_root_write_probe_argv_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  uid:int -> gid:int -> keeper_name:string -> string list

(** What a guest needs before it boots and what is checked once it is up: the
    work volume and the build volume, the shim directory and its readiness
    check, the provisions a boot gathers once no legacy Apple volume helper is
    present, the claim of the work volume at boot, the check that the work
    volume is a mountpoint in the guest, the keeper's root on it, the build
    links, and the [For_testing_microvm] module.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_boot
open Keeper_turn_sandbox_runtime_record

val microvm_shim_host_dir :
  t -> string

val verify_microvm_shim :
  base_path:string ->
  backend:Keeper_microvm_backend.t ->
  guest_name:string -> (unit, Keeper_microvm_shim_readiness.error) result

type microvm_guest_provisions =
  { work_volume_name : string
  ; build_volume_name : string option
        (** [Some] on `Apple_container`; [None] on backends whose
            work volume already returns host disk on a guest delete. *)
  ; shim_host_dir : string
  }

val ensure_apple_volume_helpers_absent :
  keeper_name:string -> timeout_sec:float -> (unit, string) result

val microvm_guest_provisions :
  t ->
  backend:Keeper_microvm_backend.t ->
  timeout_sec:float -> (microvm_guest_provisions, string) result

val ensure_microvm_work_volume_mounted :
  ?timeout_sec:float ->
  t ->
  backend:Keeper_microvm_backend.t ->
  container_name:string -> (unit, string) result

val ensure_microvm_keeper_work_root :
  ?timeout_sec:float ->
  t ->
  backend:Keeper_microvm_backend.t ->
  container_name:string -> (unit, string) result

module For_testing_microvm :
  sig
    type build_link_generation = unit ref
    val build_link_generation :
      base_path:string ->
      backend:Keeper_microvm_backend.t ->
      container_name:string -> unit ref option
    val complete_build_link_scan :
      base_path:string ->
      backend:Keeper_microvm_backend.t ->
      container_name:string -> unit ref -> bool
    val build_link_scan_prepared :
      base_path:string ->
      backend:Keeper_microvm_backend.t -> container_name:string -> bool
    val microvm_container_name :
      config:Workspace_utils_backend_setup.config ->
      keeper_name:string ->
      network_mode:Keeper_types_profile_sandbox.network_mode -> string
    val mark_microvm_work_root_ready :
      base_path:string ->
      backend:Keeper_microvm_backend.t -> container_name:string -> unit
    val microvm_work_root_ready :
      base_path:string ->
      backend:Keeper_microvm_backend.t -> container_name:string -> bool
    val microvm_identity_snapshot_registered : container_name:string -> bool
    val mark_microvm_guest_booted :
      config:Workspace_utils_backend_setup.config ->
      meta:keeper_meta -> unit -> unit
    val record_process_boot :
      container_name:string ->
      microvm_boot -> unit
    val process_boot :
      container_name:string ->
      microvm_boot option
    val register_process_identity :
      container_name:string -> cleanup:(unit -> unit) -> bool
    val ensure_work_volume_mounted :
      ?timeout_sec:float ->
      t ->
      backend:Keeper_microvm_backend.t ->
      container_name:string -> (unit, string) result
    val ensure_keeper_work_root :
      ?timeout_sec:float ->
      t ->
      backend:Keeper_microvm_backend.t ->
      container_name:string -> (unit, string) result
    val provision_guest :
      t ->
      backend:Keeper_microvm_backend.t ->
      timeout_sec:float -> (unit, string) result
  end

val ensure_microvm_build_links :
  ?timeout_sec:float ->
  t ->
  container_name:string -> generation:unit ref -> unit

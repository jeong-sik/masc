(** The guest of a keeper on the Apple container backend: reading a guest and
    checking that its labels belong to the keeper in every network mode, the
    stop of an owned guest, the image command and the policy environment read
    from the runtime, the lifecycle scope, the first handoff of a fresh guest
    and the start of the guest.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_start_failure

type apple_guest_observation =
  | Apple_absent
  | Apple_stopped of Keeper_microvm_boot_plan.reading
  | Apple_running of Keeper_microvm_boot_plan.reading

val read_apple_guest :
  timeout_sec:float ->
  container_name:string ->
  (apple_guest_observation,
   microvm_start_failure)
  result

val check_apple_guest_scope :
  base_path:string ->
  keeper_name:string ->
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  container_name:string ->
  Keeper_microvm_boot_plan.reading -> (unit, string) result

val check_apple_guest_observation :
  base_path:string ->
  keeper_name:string ->
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  container_name:string -> apple_guest_observation -> (unit, string) result

val stop_owned_apple_guest :
  base_path:string ->
  keeper_name:string ->
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  timeout_sec:float -> container_name:string -> (unit, string) result

val check_apple_guest_modes :
  base_path:string ->
  keeper_name:string -> timeout_sec:float -> (unit, string) result

val with_apple_lifecycle_scope :
  keeper_name:string ->
  unavailable:'a ->
  (fs:Eio.Fs.dir_ty Eio.Path.t ->
   scope:Keeper_microvm_lifecycle.keeper_scope -> ('b, 'a) result) ->
  ('b, 'a) result

val start_apple_microvm_container :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  scope:Keeper_microvm_lifecycle.keeper_scope ->
  timeout_sec:float ->
  t ->
  (string,
   microvm_start_failure)
  result

(** The guests a runtime lists and the sweep of the abandoned ones: the
    listing argv, the probe that classifies a guest from a listing, the live
    containers of a backend, and the sweep that removes guests no keeper
    owns.

    [Keeper_sandbox_microvm] includes this module. *)

open Keeper_sandbox_microvm_inventory

val guest_listing_argv_for : Keeper_microvm_backend.t -> string list

val classify_guest_probe_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  inspect:Unix.process_status * string ->
  listing:(Unix.process_status * string * string) option ->
  (Keeper_sandbox_runtime.docker_container_state, string) result

val list_live_containers_for :
  ?env:string array ->
  ?cwd:string ->
  Keeper_microvm_backend.t ->
  base_path:string ->
  keeper_name:string ->
  timeout_sec:float ->
  (Keeper_sandbox_runtime.live_container list, string) result

module Kata_observation_for_testing :
  sig
    val observe :
      run:(timeout_sec:float ->
           env:'a ->
           cwd:'b ->
           argv:string list -> (Unix.process_status * string, unit) result) ->
      env:'a ->
      cwd:'b ->
      base_path:string ->
      keeper_name:string ->
      network_mode:Keeper_types_profile_sandbox.network_mode ->
      timeout_sec:float ->
      kata_name_observation
    val inventory :
      run:(timeout_sec:float ->
           string list -> Unix.process_status * string * string) ->
      Keeper_microvm_backend.t ->
      base_path:string ->
      keeper_name:string ->
      timeout_sec:float ->
      (Keeper_sandbox_runtime.live_container list, string) result
  end

type sweep_outcome =
  { removed : string list
  ; failed : (string * string) list
  }

val sweep_abandoned_guests :
  base_path:string ->
  command_available:(string -> bool) ->
  timeout_sec:float ->
  is_pid_alive:(int -> bool) ->
  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string) ->
  (Keeper_microvm_backend.t * sweep_outcome) list

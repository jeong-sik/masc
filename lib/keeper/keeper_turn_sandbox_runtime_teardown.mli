(** Taking the guests and volumes of a keeper down: the sweep of abandoned
    guests of every backend, the teardown of a keeper's sandbox by name, which
    shutdown finalization runs, the removal of the volumes of a keeper, and
    the teardown of the sandbox of one turn runtime.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_meta_contract

type policy_network_removal =
  | Policy_network_removed
  | Policy_network_already_absent
  | Policy_network_kept_attached

val remove_unattached_apple_policy_network_with :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string) ->
  timeout_sec:float ->
  network_name:string ->
  (policy_network_removal, string) result

val sweep_abandoned_apple_policy_networks_with :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string) ->
  timeout_sec:float ->
  protected_keeper_names:string list ->
  revalidate:(unit -> (unit, string) result) ->
  Keeper_sandbox_microvm.sweep_outcome

val sweep_abandoned_apple_policy_networks :
  base_path:string ->
  command_available:(string -> bool) ->
  timeout_sec:float ->
  Keeper_sandbox_microvm.sweep_outcome option

val remove_apple_keeper_volumes_for_workspace_with :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string) ->
  timeout_sec:float ->
  base_path:string ->
  keeper_name:string ->
  ?sandbox_image:string ->
  unit ->
  (unit, string) result

val sweep_abandoned_microvm_guests :
  base_path:string ->
  command_available:(string -> bool) ->
  timeout_sec:float ->
  is_pid_alive:(int -> bool) ->
  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string) ->
  (Keeper_microvm_backend.t * Keeper_sandbox_microvm.sweep_outcome) list

val teardown_keeper_sandbox_by_name :
  ?timeout_sec:float ->
  config:Workspace.config ->
  keeper_name:string ->
  backend:Keeper_sandbox.backend ->
  ?microvm_backend:Keeper_microvm_backend.t ->
  unit ->
  (unit, string) result

val remove_keeper_volumes_by_name :
  ?timeout_sec:float ->
  base_path:string ->
  keeper_name:string ->
  backend:Keeper_sandbox.backend ->
  ?microvm_backend:Keeper_microvm_backend.t ->
  ?sandbox_image:string ->
  unit ->
  (unit, string) result

val teardown_keeper_sandbox :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:keeper_meta ->
  unit ->
  (unit, string) result

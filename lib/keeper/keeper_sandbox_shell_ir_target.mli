(** Sandbox target helpers for typed Shell IR dispatch. *)

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  ; class_ : Tool_result.tool_failure_class
  }

type guest_dispatch =
  { target : Masc_exec.Sandbox_target.t
  ; runtime : Keeper_turn_sandbox_runtime.t
  ; sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile
  }

type ssh_dispatch = { target : Masc_exec.Sandbox_target.t }

val target_error
  :  ?fields:(string * Yojson.Safe.t) list
  -> ?class_:Tool_result.tool_failure_class
  -> string
  -> target_error

val profile_contract_mismatch
  :  expected:Keeper_types_profile_sandbox.sandbox_profile
  -> actual:Keeper_types_profile_sandbox.sandbox_profile
  -> target_error
(** A typed pre-effect rejection for a caller meta that disagrees with the
    turn factory. *)

(** Build the Shell IR target from the factory's immutable runtime binding.
    A Docker guest runs stages by [docker exec] into its mounted tree; a
    microvm guest runs them over the remote lane into the tree it owns on
    its work volume (RFC-0400), with no pipeline runner. Neither starts its
    container here: the first stage does, and each runtime owns its
    creation-time image check. A caller meta that disagrees with the factory
    fails before dispatch. *)
val guest_target
  :  binding:Keeper_sandbox_factory.runtime_binding
  -> meta:Keeper_meta_contract.keeper_meta
  -> cwd:string
  -> timeout_sec:float
  -> unit
  -> (guest_dispatch, target_error) result

val ssh_target
  :  base_path:string
  -> meta:Keeper_meta_contract.keeper_meta
  -> timeout_sec:float
  -> ?ssh_bin:string
  -> unit
  -> (ssh_dispatch, target_error) result
(** Resolve the keeper's endpoint and construct a fail-closed SSH target.
    Pipeline dispatch remains unsupported until a native remote pipeline
    contract exists. *)

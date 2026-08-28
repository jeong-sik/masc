(** Sandbox target helpers for typed Shell IR dispatch. *)

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  ; class_ : Tool_result.tool_failure_class
  }

type docker_dispatch =
  { target : Masc_exec.Sandbox_target.t
  ; runtime : Keeper_turn_sandbox_runtime.t
  }

type ssh_dispatch = { target : Masc_exec.Sandbox_target.t }

val target_error
  :  ?fields:(string * Yojson.Safe.t) list
  -> ?class_:Tool_result.tool_failure_class
  -> string
  -> target_error

val docker_image : Keeper_meta_contract.keeper_meta -> string

val docker_target
  :  turn_sandbox_factory:Keeper_sandbox_factory.t option
  -> meta:Keeper_meta_contract.keeper_meta
  -> cwd:string
  -> ?timeout_sec:float
  -> unit
  -> (docker_dispatch, target_error) result

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

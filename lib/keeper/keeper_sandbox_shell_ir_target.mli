(** Sandbox target helpers for typed Shell IR dispatch. *)

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  }

type docker_dispatch =
  { target : Masc_exec.Sandbox_target.t
  ; runtime : Keeper_turn_sandbox_runtime.t
  }

val target_error : ?fields:(string * Yojson.Safe.t) list -> string -> target_error

val docker_image : Keeper_meta_contract.keeper_meta -> string

val docker_target
  :  turn_sandbox_factory:Keeper_sandbox_factory.t option
  -> meta:Keeper_meta_contract.keeper_meta
  -> cwd:string
  -> ?timeout_sec:float
  -> unit
  -> (docker_dispatch, target_error) result

val docker_local_fallback_target
  :  meta:Keeper_meta_contract.keeper_meta
  -> ?timeout_sec:float
  -> unit
  -> (Masc_exec.Sandbox_target.t * (string * Yojson.Safe.t) list) option

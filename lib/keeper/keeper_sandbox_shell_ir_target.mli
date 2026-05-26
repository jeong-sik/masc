(** Sandbox target helpers for typed Shell IR dispatch. *)

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  }

val target_error : ?fields:(string * Yojson.Safe.t) list -> string -> target_error

val docker_image : Keeper_types.keeper_meta -> string

val docker_target
  :  turn_sandbox_factory:Keeper_sandbox_factory.t option
  -> meta:Keeper_types.keeper_meta
  -> cwd:string
  -> timeout_sec:float
  -> (Masc_exec.Sandbox_target.t, target_error) result

val docker_local_fallback_target
  :  meta:Keeper_types.keeper_meta
  -> timeout_sec:float
  -> (Masc_exec.Sandbox_target.t * (string * Yojson.Safe.t) list) option

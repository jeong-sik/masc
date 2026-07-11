(** Sandbox target helpers for typed Shell IR dispatch. *)

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  }

val target_error : ?fields:(string * Yojson.Safe.t) list -> string -> target_error

val docker_image : Keeper_meta_contract.keeper_meta -> string

val docker_target
  :  turn_sandbox_factory:Keeper_sandbox_factory.t option
  -> meta:Keeper_meta_contract.keeper_meta
  -> cwd:string
  -> (Masc_exec.Sandbox_target.t, target_error) result

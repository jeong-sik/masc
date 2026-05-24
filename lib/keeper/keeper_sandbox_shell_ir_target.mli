(** Sandbox target helpers for typed Shell IR dispatch. *)

val docker_image : Keeper_types.keeper_meta -> string

val docker_target
  :  turn_sandbox_factory:Keeper_sandbox_factory.t option
  -> meta:Keeper_types.keeper_meta
  -> cwd:string
  -> (Masc_exec.Sandbox_target.t, string) result

val docker_runtime_failure_fields : string -> (string * Yojson.Safe.t) list

val docker_local_fallback_target
  :  meta:Keeper_types.keeper_meta
  -> timeout_sec:float
  -> (Masc_exec.Sandbox_target.t * (string * Yojson.Safe.t) list) option

(** Docker sandbox helpers for typed keeper_bash Shell IR dispatch. *)

val typed_docker_image : Keeper_types.keeper_meta -> string

val typed_docker_sandbox_target
  :  turn_sandbox_factory:Keeper_sandbox_factory.t option
  -> meta:Keeper_types.keeper_meta
  -> cwd:string
  -> (Masc_exec.Sandbox_target.t, string) result

val typed_docker_runtime_failure_fields : string -> (string * Yojson.Safe.t) list

val typed_docker_local_fallback_target
  :  meta:Keeper_types.keeper_meta
  -> timeout_sec:float
  -> (Masc_exec.Sandbox_target.t * (string * Yojson.Safe.t) list) option

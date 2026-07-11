(** Sandbox target helpers for typed Shell IR dispatch. *)

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  }

val target_error : ?fields:(string * Yojson.Safe.t) list -> string -> target_error

(** First keeper env entry ("K=V" or bare "K") whose key is in
    [Keeper_sandbox_runtime.docker_sandbox_reserved_env_keys], as the key.
    [None] when every entry is safe to inject as a [docker exec --env]
    flag. Dispatch rejects a colliding entry with a typed error because
    [docker exec] resolves duplicate [--env] flags last-wins, which would
    silently override a sandbox invariant. *)
val reserved_env_collision : string array -> string option

val docker_image : Keeper_meta_contract.keeper_meta -> string

val docker_target
  :  turn_sandbox_factory:Keeper_sandbox_factory.t option
  -> meta:Keeper_meta_contract.keeper_meta
  -> cwd:string
  -> (Masc_exec.Sandbox_target.t, target_error) result

val docker_local_fallback_target
  :  meta:Keeper_meta_contract.keeper_meta
  -> (Masc_exec.Sandbox_target.t * (string * Yojson.Safe.t) list) option

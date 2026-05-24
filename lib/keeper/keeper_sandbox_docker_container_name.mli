(** Docker container naming + host-cwd → container-cwd translation
    for the keeper sandbox. *)

val keeper_sandbox_container_name : Keeper_types.keeper_meta -> string

val keeper_private_container_root : Keeper_types.keeper_meta -> string

val docker_private_workspace_cwd
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> string
  -> string

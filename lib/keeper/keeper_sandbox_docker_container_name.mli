(** Docker container naming + host-cwd → container-cwd translation
    for the keeper sandbox. *)

val keeper_sandbox_container_name : Keeper_meta_contract.keeper_meta -> string

val keeper_private_container_root : Keeper_meta_contract.keeper_meta -> string

val docker_private_workspace_cwd
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string
  -> string

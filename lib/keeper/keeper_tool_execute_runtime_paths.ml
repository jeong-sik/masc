open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let rewrite_turn_runtime_paths_to_host
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      text
  =
  Keeper_sandbox.rewrite_container_paths_to_host
    (Keeper_sandbox.docker_mount_layout_of_meta ~config meta)
    text

let rewrite_docker_host_paths_to_container
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      text
  =
  Keeper_sandbox.rewrite_host_paths_to_container
    (Keeper_sandbox.docker_mount_layout_of_meta ~config meta)
    text

open Keeper_types
open Keeper_exec_shared

let keeper_private_container_root =
  Keeper_shell_docker_container_name.keeper_private_container_root

let rewrite_docker_command_paths ~(config : Coord.config) ~(meta : keeper_meta) cmd =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let normalized_host_root =
    raw_host_root |> Keeper_alerting_path.normalize_path_for_check_stripped
  in
  let container_root = keeper_private_container_root meta in
  let rewritten =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:raw_host_root
      ~container_root
      cmd
  in
  if String.equal raw_host_root normalized_host_root
  then rewritten
  else
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:normalized_host_root
      ~container_root
      rewritten
;;

let rewrite_docker_command_paths_for_host_validation
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      cmd
  =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let normalized_host_root =
    raw_host_root |> Keeper_alerting_path.normalize_path_for_check_stripped
  in
  let container_root =
    keeper_private_container_root meta |> Keeper_alerting_path.strip_trailing_slashes
  in
  let rewritten =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:container_root
      ~container_root:raw_host_root
      cmd
  in
  if String.equal raw_host_root normalized_host_root
  then rewritten
  else
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:container_root
      ~container_root:normalized_host_root
      rewritten
;;

(** Docker [docker run] argv construction.

    Pure-data transformation: assembles the complete [docker run --rm …]
    argument vector from resolved parameters.  No I/O, no side effects. *)

open Keeper_types

let docker_run_argv
      ~config
      ~meta
      ~container_name
      ~container_root
      ~container_cwd
      ~host_root
      ~network_label
      ~network_args
      ~uid
      ~gid
      ~seccomp_args
      ~cred_mounts
      ~cred_envs
      ~identity_mounts
      ~image
      ~ttl_sec
  =
  Keeper_sandbox_runtime.docker_command_argv ()
  @ [ "run"; "--rm"; "--name"; container_name ]
  @ Keeper_sandbox_runtime.docker_label_args
      ~base_path:config.base_path
      ~keeper_name:meta.name
      ~container_kind:"oneshot"
      ~network_label
      ~ttl_sec
      ()
  @ [ "-i"; "--user"; Printf.sprintf "%d:%d" uid gid ]
  @ Keeper_sandbox_runtime.docker_sandbox_env_args
      ~base_path:config.base_path
      ~container_root
  @ Keeper_sandbox_runtime.docker_nofile_args ()
  @ Env_config_keeper.KeeperSandbox.read_only_rootfs_args ()
  @ [ "--tmpfs"
    ; Env_config_keeper.KeeperSandbox.tmpfs_mount ()
    ; "--cap-drop=ALL"
    ; "--security-opt"
    ; "no-new-privileges"
    ]
  @ seccomp_args
  @ [ "--pids-limit"
    ; string_of_int (Env_config_keeper.KeeperSandbox.pids_limit ())
    ; "--memory"
    ; Env_config_keeper.KeeperSandbox.memory ()
    ; "-v"
    ; host_root ^ ":" ^ container_root ^ ":rw"
    ; "--workdir"
    ; container_cwd
    ]
  @ Keeper_sandbox_runtime.docker_config_mount_args
      ~base_path:config.base_path
      ~container_root
  @ Keeper_sandbox_runtime.docker_room_state_mount_args
      ~base_path:config.base_path
      ~container_root
  @ network_args
  @ cred_mounts
  @ cred_envs
  @ identity_mounts
  @ [ image; "bash"; "-l"; "-s" ]
;;

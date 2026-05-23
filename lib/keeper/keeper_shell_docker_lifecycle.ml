open Keeper_types
open Keeper_exec_shared

let docker_run_min_timeout_sec =
  let floor = Timeout_floor.Docker_run in
  let default = Timeout_floor.default_sec floor in
  let raw =
    try float_of_string (Sys.getenv "MASC_KEEPER_DOCKER_RUN_MIN_TIMEOUT_SEC")
    with Not_found | Failure _ -> default
  in
  Timeout_floor.clamp floor raw

let docker_cleanup_rm_timeout_sec () =
  Env_config_sandbox.Shell_timeout.timeout_sec
    ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
    ()
;;

let docker_oneshot_ttl_sec ~timeout_sec =
  timeout_sec +. docker_cleanup_rm_timeout_sec () +. 10.0
;;

let docker_rm_no_such_container text =
  String_util.contains_substring_ci text "no such container"
  || String_util.contains_substring_ci text "no such object"
;;

let cleanup_oneshot_container ~container_name =
  let argv = Keeper_sandbox_runtime.docker_command_argv () @ [ "rm"; "-f"; container_name ] in
  let status, output =
    Docker_spawn_throttle.with_slot (fun () ->
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:`System_task_sandbox
        ~raw_source:(String.concat " " argv)
        ~summary:"keeper docker oneshot cleanup"
        ~env:(Unix.environment ())
        ~cwd:(Sys.getcwd ())
        ~timeout_sec:(docker_cleanup_rm_timeout_sec ())
        argv)
  in
  match status with
  | Unix.WEXITED 0 -> ()
  | _ when docker_rm_no_such_container output -> ()
  | _ ->
    Log.Keeper.warn
      "docker oneshot cleanup failed for %s (status=%s, output=%s)"
      container_name
      (docker_exec_status_label status)
      (Exec_policy.truncate_for_log output)
;;

let fd_admission_error ~(config : Coord.config) =
  let active_keepers = Keeper_registry.count_running ~base_path:config.base_path () in
  match
    Keeper_fd_pressure.admission_decision
      ~active_keepers
      ~starting_keepers:0
      ()
  with
  | Keeper_fd_pressure.Admit -> None
  | Keeper_fd_pressure.Block block ->
    Some
      (Printf.sprintf
         "docker_shell_failed: fd_pressure: %s"
         (Keeper_fd_pressure.admission_block_kind block))
;;


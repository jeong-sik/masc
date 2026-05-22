(* Docker sandbox helpers for typed keeper_bash Shell IR dispatch.
   Extracted from [Keeper_shell_bash] (godfile decomp). *)

open Keeper_types

let typed_docker_image (meta : keeper_meta) =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
;;

let typed_docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd =
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | None ->
    Error
      "typed Bash Docker Shell IR dispatch requires a turn sandbox factory"
  | Some runtime ->
    let image = typed_docker_image meta in
    let runner ~stdin_content ~argv ~env:_ ~cwd:stage_cwd ~timeout_sec =
      let cwd = Option.value stage_cwd ~default:cwd in
      match
        Keeper_turn_sandbox_runtime.run_exec_with_status
          ?stdin_content
          runtime
          ~timeout_sec
          ~cwd
          ~command_argv:argv
      with
      | Ok (status, output) -> status, output, ""
      | Error err -> Unix.WEXITED 1, "", err
    in
    let pipeline_runner ~stages ~timeout_sec =
      let stages =
        List.map
          (fun stage ->
            { Keeper_turn_sandbox_runtime.command_argv = stage.Masc_exec.Sandbox_target.argv
            ; cwd = stage.cwd
            })
          stages
      in
      match
        Keeper_turn_sandbox_runtime.run_exec_pipeline_with_status
          runtime
          ~timeout_sec
          ~cwd
          ~stages
      with
      | Ok result -> result
      | Error err -> Unix.WEXITED 1, "", err
    in
    Ok (Masc_exec.Sandbox_target.docker ~image ~runner ~pipeline_runner ())
;;

let typed_docker_runtime_failure_fields output =
  if String_util.contains_substring output "sandbox_image_missing"
  then [ "failure_class", `String "policy_rejection" ]
  else []
;;

let typed_docker_local_fallback_target ~meta ~timeout_sec =
  let image = typed_docker_image meta in
  match Keeper_sandbox_runtime.docker_image_present ~image ~timeout_sec with
  | Ok () -> None
  | Error message ->
    Some
      ( Masc_exec.Sandbox_target.host ()
      , [ "requested_sandbox", `String "docker"
        ; "sandbox_fallback", `String "local_playground"
        ; "sandbox_fallback_reason", `String (Exec_policy.truncate_for_log message)
        ] )
;;

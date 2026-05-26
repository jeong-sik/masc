(* Sandbox target helpers for typed Shell IR dispatch. *)

open Keeper_types

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  }

let target_error ?(fields = []) message = { message; fields }

let docker_image (meta : keeper_meta) =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_sandbox.Runtime.docker_image ()
;;

let tool_failure_class_of_image_preflight_failure = function
  | "image_config_missing"
  | "image_missing" ->
    "policy_rejection"
  | "docker_daemon_unavailable"
  | "image_inspect_timeout" ->
    "transient_error"
  | _ -> "runtime_failure"
;;

let image_preflight_failure_fields (failure : Keeper_sandbox_runtime.classified_error)
  =
  [ "requested_sandbox", `String "docker"
  ; "sandbox_failure_class", `String failure.failure_class
  ; ( "failure_class"
    , `String (tool_failure_class_of_image_preflight_failure failure.failure_class) )
  ]
;;

let image_preflight_target_error (failure : Keeper_sandbox_runtime.classified_error) =
  target_error
    ~fields:(image_preflight_failure_fields failure)
    (Keeper_sandbox_runtime.docker_image_preflight_failure_message
       ~prefix:"docker_container_start_failed"
       failure)
;;

let docker_target ~turn_sandbox_factory ~meta ~cwd ~timeout_sec =
  let default_cwd = cwd in
  let stage_cwd_or_default = function
    | Some stage_cwd -> stage_cwd
    | None -> default_cwd
  in
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | None ->
    Error (target_error "typed Shell IR Docker dispatch requires a turn sandbox factory")
  | Some runtime ->
    let image = docker_image meta in
    (match
       Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class
         ~image
         ~timeout_sec
     with
     | Error failure -> Error (image_preflight_target_error failure)
     | Ok () ->
       let runner ~stdin_content ~argv ~env:_ ~cwd:stage_cwd ~timeout_sec =
         let cwd = stage_cwd_or_default stage_cwd in
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
                { Keeper_turn_sandbox_runtime.command_argv =
                    stage.Masc_exec.Sandbox_target.argv
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
       Ok (Masc_exec.Sandbox_target.docker ~image ~runner ~pipeline_runner ()))
;;

let docker_local_fallback_target ~meta ~timeout_sec =
  let image = docker_image meta in
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

(* Sandbox target helpers for typed Shell IR dispatch. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

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

let tool_failure_class_of_image_preflight_failure failure_class =
  match failure_class with
  | Keeper_sandbox_runtime_classify.Image_config_missing
  | Image_missing ->
    "policy_rejection"
  | Docker_daemon_unavailable
  | Image_inspect_timeout ->
    "transient_error"
  | _ -> "runtime_failure"
;;

let image_preflight_failure_fields (failure : Keeper_sandbox_runtime.classified_error) =
  let sandbox_failure_class =
    Keeper_sandbox_runtime_classify.docker_failure_class_to_string failure.failure_class
  in
  [ "requested_sandbox", `String "docker"
  ; "sandbox_failure_class", `String sandbox_failure_class
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

(* Per PR cleanup spirit (caller does not observe the tool's hang
   protection): the docker target hardcodes its own internal timeout.
   The image-presence check, [docker exec] of a single command, and the
   pipeline dispatch all share the same internal budget because the
   hang modes (docker daemon stall, container start stall, command
   stall) are the same domain — the sandbox's own. *)
let internal_sandbox_timeout_sec = 30.0

let docker_target ~turn_sandbox_factory ~meta ~cwd =
  let default_cwd = cwd in
  let stage_cwd_or_default = function
    | Some stage_cwd -> stage_cwd
    | None -> default_cwd
  in
  let timeout_sec = internal_sandbox_timeout_sec in
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | No_factory ->
    Error
      (target_error
         "typed Shell IR Docker dispatch requires a turn sandbox factory (no factory provided)")
  | Local_profile ->
    Error
      (target_error
         "typed Shell IR Docker dispatch requires a turn sandbox factory (sandbox profile is Local)")
  | Runtime runtime ->
    let image = docker_image meta in
    (match
       Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class
         ~image
         ~timeout_sec
     with
     | Error failure -> Error (image_preflight_target_error failure)
     | Ok () ->
      let runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd:stage_cwd =
        let cwd = stage_cwd_or_default stage_cwd in
        match
          Keeper_turn_sandbox_runtime.run_exec_with_status_split
            ?stdin_content
            ?on_stdout_chunk
            ?on_stderr_chunk
            ~env
            ~timeout_sec
            runtime
            ~cwd
            ~command_argv:argv
        with
        | Ok result -> result
        | Error err -> Unix.WEXITED 1, "", err
       in
      let pipeline_runner ~on_stdout_chunk ~on_stderr_chunk ~stages =
        let stages =
          List.map
            (fun stage ->
              { Keeper_turn_sandbox_runtime.command_argv =
                  stage.Masc_exec.Sandbox_target.argv
              ; cwd = stage.cwd
              ; env = stage.env
              })
            stages
        in
        match
          Keeper_turn_sandbox_runtime.run_exec_pipeline_with_status
            ?on_stdout_chunk
            ?on_stderr_chunk
            ~timeout_sec
            runtime
            ~cwd
            ~stages
        with
        | Ok result -> result
        | Error err -> Unix.WEXITED 1, "", err
       in
       Ok (Masc_exec.Sandbox_target.docker ~image ~runner ~pipeline_runner ()))
;;

let docker_local_fallback_target ~meta =
  let image = docker_image meta in
  match
    Keeper_sandbox_runtime.docker_image_present
      ~image
      ~timeout_sec:internal_sandbox_timeout_sec
  with
  | Ok () -> None
  | Error message ->
    Some
      ( Masc_exec.Sandbox_target.host ()
      , [ "requested_sandbox", `String "docker"
        ; "sandbox_fallback", `String "local_playground"
        ; "sandbox_fallback_reason", `String (Exec_policy.truncate_for_log message)
        ] )
;;

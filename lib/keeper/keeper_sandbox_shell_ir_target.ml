(* Sandbox target helpers for typed Shell IR dispatch. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  ; class_ : Tool_result.tool_failure_class
  }

type guest_dispatch =
  { target : Masc_exec.Sandbox_target.t
  ; runtime : Keeper_turn_sandbox_runtime.t
  }

type ssh_dispatch = { target : Masc_exec.Sandbox_target.t }

type guest_profile =
  | Docker_guest
  | Micro_vm_guest

let target_error ?(fields = []) ?(class_ = Tool_result.Runtime_failure) message =
  { message; fields; class_ }
;;

let guest_image (meta : keeper_meta) =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_sandbox.Runtime.docker_image ()
;;

let tool_failure_class_of_image_preflight_failure failure_class =
  match failure_class with
  | Keeper_sandbox_runtime_classify.Image_config_missing ->
    Tool_result.Policy_rejection
  | Image_inspect_timeout ->
    Tool_result.Dependency_unavailable
  | _ -> Tool_result.Runtime_failure
;;

let image_preflight_failure_fields ~class_
    (failure : Keeper_sandbox_runtime.classified_error) =
  let sandbox_failure_class =
    Keeper_sandbox_runtime_classify.docker_failure_class_to_string failure.failure_class
  in
  [ "requested_sandbox", `String "docker"
  ; "sandbox_failure_class", `String sandbox_failure_class
  ; ( "failure_class"
    , `String (Tool_result.tool_failure_class_to_string class_) )
  ]
;;

let image_preflight_target_error (failure : Keeper_sandbox_runtime.classified_error) =
  let class_ = tool_failure_class_of_image_preflight_failure failure.failure_class in
  target_error
    ~class_
    ~fields:(image_preflight_failure_fields ~class_ failure)
    (Keeper_sandbox_runtime.docker_image_preflight_failure_message
       ~prefix:"docker_container_start_failed"
       failure)
;;

let docker_image_preflight ~image ~timeout_sec =
  Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class_optional
    ~image
    ?timeout_sec
    ()
;;

let guest_target_with_docker_image_preflight
      ~docker_image_preflight
      ~turn_sandbox_factory
      ~(meta : keeper_meta)
      ~cwd
      ?timeout_sec
      ()
  =
  let default_cwd = cwd in
  let stage_cwd_or_default = function
    | Some stage_cwd -> stage_cwd
    | None -> default_cwd
  in
  let guest_profile =
    match meta.sandbox_profile with
    | Docker -> Ok Docker_guest
    | Micro_vm -> Ok Micro_vm_guest
    | Remote_ssh ->
      Error
        (target_error
           "remote_ssh_dispatch_unavailable: typed Shell IR guest dispatch does not apply to sandbox_profile=remote_ssh; that profile dispatches through the SSH runner instead")
  in
  match guest_profile with
  | Error _ as error -> error
  | Ok guest_profile ->
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | No_factory ->
    Error
      (target_error
         "typed Shell IR guest dispatch requires a turn sandbox factory (no factory provided)")
  | Remote_ssh_profile ->
    (* The factory and the admitted profile must describe the same target. *)
    Error
      (target_error
         "typed Shell IR guest dispatch received a remote_ssh sandbox factory")
  | Runtime runtime ->
    let image = guest_image meta in
    let image_preflight =
      match guest_profile with
      | Docker_guest ->
        docker_image_preflight ~image ~timeout_sec
        |> Result.map_error image_preflight_target_error
      | Micro_vm_guest -> Ok ()
    in
    (match image_preflight
     with
     | Error _ as error -> error
     | Ok () ->
      let runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd:stage_cwd =
        if Array.length env > 0 then
          (Unix.WEXITED 1, "", "typed Shell IR guest dispatch does not support env yet")
        else
          let cwd = stage_cwd_or_default stage_cwd in
          match
            Keeper_turn_sandbox_runtime.run_exec_with_status_split
              ?stdin_content
              ?on_stdout_chunk
              ?on_stderr_chunk
              ?timeout_sec
              runtime
              ~cwd
              ~command_argv:argv
           with
           | Ok result -> result
           | Error err -> Unix.WEXITED 1, "", err
       in
      let pipeline_runner ~on_stdout_chunk ~on_stderr_chunk ~stages =
        match
          List.find_opt
            (fun stage -> Array.length stage.Masc_exec.Sandbox_target.env > 0)
             stages
         with
         | Some _ ->
           (Unix.WEXITED 1, "", "typed Shell IR guest dispatch does not support env yet")
         | None ->
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
              ?on_stdout_chunk
              ?on_stderr_chunk
              ?timeout_sec
              runtime
              ~cwd
              ~stages
           with
           | Ok result -> result
           | Error err -> Unix.WEXITED 1, "", err
       in
       let target =
         match guest_profile with
         | Docker_guest ->
           Masc_exec.Sandbox_target.docker ~image ~runner ~pipeline_runner ()
         | Micro_vm_guest ->
           Masc_exec.Sandbox_target.micro_vm ~image ~runner ~pipeline_runner ()
       in
       Ok { target; runtime })
;;

let guest_target =
  guest_target_with_docker_image_preflight ~docker_image_preflight
;;

module For_testing = struct
  let guest_target_with_docker_image_preflight =
    guest_target_with_docker_image_preflight
end

let ssh_target ~base_path ~meta ~timeout_sec ?ssh_bin () =
  match Keeper_sandbox_ssh.resolve_endpoint ~base_path ~keeper_name:meta.name with
  | Error message ->
    Error
      (target_error ~class_:Tool_result.Policy_rejection
         ~fields:[ "requested_sandbox", `String "remote_ssh" ] message)
  | Ok endpoint ->
    (match
       Keeper_sandbox_ssh.create ?ssh_bin ~base_path ~keeper_name:meta.name
         ~endpoint ()
     with
     | Error message ->
       Error
         (target_error ~class_:Tool_result.Dependency_unavailable
            ~fields:
              [ "requested_sandbox", `String "remote_ssh"
              ; "remote_endpoint", `String endpoint.name
              ]
            message)
     | Ok ssh ->
       let readiness =
         if Env_config_sandbox.Preflight.enabled ()
         then Keeper_sandbox_ssh.check_preflight ssh
         else Ok ()
       in
       (match readiness with
        | Error message ->
          Error
            (target_error ~class_:Tool_result.Dependency_unavailable
               ~fields:
                 [ "requested_sandbox", `String "remote_ssh"
                 ; "remote_endpoint", `String endpoint.name
                 ]
               message)
        | Ok () ->
          let runner = Keeper_sandbox_ssh.runner ~timeout_sec ssh in
          Ok
            { target =
                Masc_exec.Sandbox_target.ssh
                  ~endpoint:(Keeper_sandbox_ssh.sandbox_endpoint ssh)
                  ~runner ()
            }))
;;

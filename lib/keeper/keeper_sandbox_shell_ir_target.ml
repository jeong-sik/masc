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
  ; sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile
  }

type ssh_dispatch = { target : Masc_exec.Sandbox_target.t }

type guest_profile =
  | Docker_guest
  | Micro_vm_guest

let target_error ?(fields = []) ?(class_ = Tool_result.Runtime_failure) message =
  { message; fields; class_ }
;;

let profile_label = Keeper_types_profile_sandbox.sandbox_profile_to_string

let profile_contract_mismatch ~expected ~actual =
  let expected_label = profile_label expected in
  let actual_label = profile_label actual in
  target_error
    ~class_:Tool_result.Policy_rejection
    ~fields:
      [ "code", `String "sandbox_profile_contract_mismatch"
      ; "expected_sandbox_profile", `String expected_label
      ; "factory_sandbox_profile", `String actual_label
      ]
    (Printf.sprintf
       "sandbox profile contract mismatch: caller expected %s but the turn factory froze %s"
       expected_label
       actual_label)
;;

let guest_target
      ~(binding : Keeper_sandbox_factory.runtime_binding)
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
  let sandbox_profile, guest_profile =
    match binding.guest_profile with
    | Keeper_sandbox_factory.Docker_guest -> Docker, Docker_guest
    | Keeper_sandbox_factory.Micro_vm_guest -> Micro_vm, Micro_vm_guest
  in
  if sandbox_profile <> meta.sandbox_profile
  then
    Error
      (profile_contract_mismatch
         ~expected:meta.sandbox_profile
         ~actual:sandbox_profile)
  else
    let runtime = binding.runtime in
    let image = binding.image in
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
     Ok { target; runtime; sandbox_profile }
;;

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

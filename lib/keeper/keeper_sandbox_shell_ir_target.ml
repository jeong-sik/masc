(* Sandbox target helpers for typed Shell IR dispatch. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  ; class_ : Tool_result.tool_failure_class
  }

type observe_route =
  | Boxed of
      { target : Masc_exec.Sandbox_target.t
      ; run : Keeper_types_profile_sandbox.observation_run
      }
  | No_box of string

type guest_dispatch =
  { target : Masc_exec.Sandbox_target.t
  ; runtime : Keeper_turn_sandbox_runtime.t
  ; sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile
  ; observe_route : unit -> observe_route
  }

type ssh_dispatch =
  { target : Masc_exec.Sandbox_target.t
  ; observe_route : unit -> observe_route
  }

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

(* The Docker guest mounts the keeper's tree, so a stage runs by [docker exec]
   with the host cwd mapped to its guest spelling. Both runners start the
   container on first use rather than at target construction. *)
let docker_runners ~runtime ~timeout_sec ~cwd =
  let default_cwd = cwd in
  let stage_cwd_or_default = function
    | Some stage_cwd -> stage_cwd
    | None -> default_cwd
  in
  let runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd:stage_cwd =
    if Array.length env > 0 then
      Masc_exec.Sandbox_target.Transport_failed
        { reason = "typed Shell IR guest dispatch does not support env yet"
        ; stdout = ""
        ; stderr = "typed Shell IR guest dispatch does not support env yet"
        }
    else
      let cwd = stage_cwd_or_default stage_cwd in
      match
        Keeper_turn_sandbox_runtime.run_exec_with_status_split
          ?stdin_content
          ?on_stdout_chunk
          ?on_stderr_chunk
          ~timeout_sec
          runtime
          ~cwd
          ~command_argv:argv
       with
       | Ok (status, stdout, stderr) ->
         Masc_exec.Sandbox_target.Ran { status; stdout; stderr }
       | Error err ->
         Masc_exec.Sandbox_target.Transport_failed
           { reason = err; stdout = ""; stderr = err }
   in
  let pipeline_runner ~on_stdout_chunk ~on_stderr_chunk ~stages =
    match
      List.find_opt
        (fun stage -> Array.length stage.Masc_exec.Sandbox_target.env > 0)
         stages
     with
     | Some _ ->
       Masc_exec.Sandbox_target.Transport_failed
         { reason = "typed Shell IR guest dispatch does not support env yet"
         ; stdout = ""
         ; stderr = "typed Shell IR guest dispatch does not support env yet"
         }
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
          ~timeout_sec
          runtime
          ~cwd
          ~stages
       with
       | Ok (status, stdout, stderr) ->
         Masc_exec.Sandbox_target.Ran { status; stdout; stderr }
       | Error err ->
         Masc_exec.Sandbox_target.Transport_failed
           { reason = err; stdout = ""; stderr = err }
   in
   runner, pipeline_runner
;;

(* A microvm guest owns its tree on the work volume (RFC-0400), so a stage
   travels the remote lane: the framed request reaches the guest's shim over
   [container exec], and the remote runner translates the host cwd into the
   guest's spelling. The endpoint is acquired per call, which is what boots
   the guest on first use and re-boots one that went away; a boot that fails
   is the stage's failure, as a Docker container that will not start is. No
   pipeline runner, as for an OpenSSH endpoint: the shim runs one command
   per connection. *)
let microvm_runner ~runtime ~timeout_sec =
  fun ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd ->
    match Keeper_sandbox_remote_lane.microvm_endpoint ~timeout_sec runtime with
    | Error err ->
      Masc_exec.Sandbox_target.Transport_failed
        { reason = err; stdout = ""; stderr = err }
    | Ok endpoint ->
      Keeper_sandbox_remote.runner ~timeout_sec endpoint
        ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd
;;

let protocol_mode_of_run = function
  | Keeper_types_profile_sandbox.Observe -> Exec_ssh_protocol.Observe
  | Keeper_types_profile_sandbox.Guest_local -> Exec_ssh_protocol.Guest_local
;;

(* Read at the moment the route is resolved, as [remote_endpoint] is
   ({!Keeper_sandbox_ssh.resolve_endpoint}), rather than carried on keeper
   meta: the switch is TOML-owned, and meta has a constructor at every site
   that would have to learn a field no dispatch reads. *)
let observation_run_for ~base_path ~keeper_name =
  match
    Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path
      keeper_name
  with
  | Ok defaults ->
    Ok
      (Option.value
         defaults.observation_run
         ~default:Keeper_types_profile_sandbox.default_observation_run)
  | Error error -> Error (Keeper_types_profile.keeper_toml_load_error_to_string error)
;;

(* The box for one endpoint (RFC-0422): the same transport, with the request
   asking the shim for the box the keeper TOML chose. Built only after the
   shim has said it can build one, so a runner here never asks a shim that
   would refuse; a shim that predates the box, or a host without Landlock,
   is a [No_box] with the endpoint named, and the request keeps the judge.

   [Guest_local] lets writes land inside the guest. On a microvm that is the
   keeper's own volume and nothing else (RFC-0422 §1.2). On an OpenSSH
   endpoint it is the account's home, which is the keeper's alone only when
   the operator has said so in runtime.toml ([private_home = true]); without
   that declaration the request keeps the judge rather than writing where
   someone else may also live. *)
let observe_route_for_endpoint ~run ~timeout_sec ~target_of_runner endpoint =
  match run, Keeper_sandbox_remote.transport endpoint with
  | ( Keeper_types_profile_sandbox.Guest_local
    , Keeper_sandbox_remote.Openssh { endpoint = declared; _ } )
    when not declared.Exec_ssh_endpoint.private_home ->
    No_box
      (Printf.sprintf
         "remote_ssh_guest_local_requires_private_home: the keeper asks \
          observation_run = \"guest_local\", but endpoint %s does not declare \
          private_home = true; a guest_local box writes inside the account, and \
          the operator has not said the account is this keeper's alone"
         declared.Exec_ssh_endpoint.name)
  | ( (Keeper_types_profile_sandbox.Observe | Keeper_types_profile_sandbox.Guest_local)
    , (Keeper_sandbox_remote.Openssh _ | Keeper_sandbox_remote.Container_exec _) ) ->
    if Keeper_sandbox_remote.observe_supported endpoint
    then
      Boxed
        { target =
            target_of_runner
              (Keeper_sandbox_remote.runner
                 ~mode:(protocol_mode_of_run run)
                 ~timeout_sec
                 endpoint)
        ; run
        }
    else
      No_box
        (Printf.sprintf
           "%s_observe_unsupported: the shim at endpoint %s advertises no observe capability"
           (Keeper_sandbox_remote.lane_prefix (Keeper_sandbox_remote.transport endpoint))
           (Keeper_sandbox_remote.name endpoint))
;;

let docker_has_no_box =
  "docker_observe_unsupported: a Docker guest runs no masc-exec-shim, and the box is the shim's"
;;

let guest_target
      ~(binding : Keeper_sandbox_factory.runtime_binding)
      ~(meta : keeper_meta)
      ~cwd
      ~timeout_sec
      ~base_path
      ()
  =
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
    let target, observe_route =
      match guest_profile with
      | Docker_guest ->
        let runner, pipeline_runner = docker_runners ~runtime ~timeout_sec ~cwd in
        ( Masc_exec.Sandbox_target.docker ~image ~runner ~pipeline_runner ()
        , fun () -> No_box docker_has_no_box )
      | Micro_vm_guest ->
        ( Masc_exec.Sandbox_target.micro_vm
            ~image
            ~runner:(microvm_runner ~runtime ~timeout_sec)
            ()
        , fun () ->
            match observation_run_for ~base_path ~keeper_name:meta.name with
            | Error reason -> No_box reason
            | Ok run ->
              (match Keeper_sandbox_remote_lane.microvm_endpoint ~timeout_sec runtime with
               | Error err -> No_box err
               | Ok endpoint ->
                 observe_route_for_endpoint
                   ~run
                   ~timeout_sec
                   ~target_of_runner:(fun runner ->
                     Masc_exec.Sandbox_target.micro_vm ~image ~runner ())
                   endpoint) )
    in
    Ok { target; runtime; sandbox_profile; observe_route }
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
         then Keeper_sandbox_remote.check_preflight ssh
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
          let runner = Keeper_sandbox_remote.runner ~timeout_sec ssh in
          let sandbox_endpoint = Keeper_sandbox_ssh.sandbox_endpoint ~base_path endpoint in
          Ok
            { target =
                Masc_exec.Sandbox_target.ssh ~endpoint:sandbox_endpoint ~runner ()
            ; observe_route =
                (fun () ->
                  match observation_run_for ~base_path ~keeper_name:meta.name with
                  | Error reason -> No_box reason
                  | Ok run ->
                    observe_route_for_endpoint
                      ~run
                      ~timeout_sec
                      ~target_of_runner:(fun runner ->
                        Masc_exec.Sandbox_target.ssh ~endpoint:sandbox_endpoint ~runner ())
                      ssh)
            }))
;;

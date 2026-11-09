open Keeper_meta_contract
open Keeper_types_profile
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_run_argv
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_start_failure
open Keeper_turn_sandbox_runtime_process_bound
open Keeper_turn_sandbox_runtime_apple

let start_microvm_container ?timeout_sec t =
  let result = match microvm_backend_of t with
    | Error detail -> Error (Backend_unresolved detail)
    | Ok Keeper_microvm_backend.Apple_container ->
      let timeout_sec = match timeout_sec with
        | Some seconds -> seconds
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
      with_apple_lifecycle_scope ~keeper_name:t.meta.name ~unavailable:Runtime_context_unavailable
        (fun ~fs ~scope -> start_apple_microvm_container ~fs ~scope ~timeout_sec t)
    | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
      with_microvm_lifecycle_lock ~keeper_name:t.meta.name ~operation:"start_adopt"
        (fun () -> start_process_bound_microvm_container ?timeout_sec t) in
  Result.map_error microvm_start_failure_cause result
;;

let start_container ?timeout_sec (t : t) =
  if is_microvm t
  then start_microvm_container ?timeout_sec t
  else
  (* Only the two refusals of the GitHub identity below blame the Keeper's
     login; every other failure is the container's. *)
  let sandbox_failed detail = Error (Sandbox_unavailable detail) in
  match t.image with
  | Error error -> sandbox_failed (image_unresolved_message error)
  | Ok image ->
  let container_name = docker_container_name_for_image t ~image in
  let probe_state () =
    Keeper_sandbox_runtime.probe_container_state_optional
      ~container_name
      ?timeout_sec
      ()
  in
  let adopt_running () =
    (* The mount is the live config directory, so a login that happened while
       no turn was watching only needs the derived gitconfig rewritten; the
       env baked at creation keeps pointing at the same file. A malformed
       identity state is a typed error here exactly as it is at creation. *)
    match
      Keeper_github_identity.refresh_git_credential_config
        ~config:t.config
        ~keeper_name:t.meta.name
    with
    | Error err ->
      Error
        (Identity_unavailable
           ("docker_container_adopt_failed: github_identity_invalid: " ^ err))
    | Ok _has_git_wiring ->
      set_state t (Running { container_name });
      Ok container_name
  in
  (* Creation is the only path that needs the image, the runtime hardening
     args, and the projections; adoption amortises all of it. *)
  let create () =
    (
      match
        Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class_optional
          ~image
          ?timeout_sec
          ()
      with
      | Error failure ->
        sandbox_failed (Keeper_sandbox_runtime.image_preflight_start_error failure)
      | Ok () ->
        match
          Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime_optional
            ?timeout_sec ()
        with
        | Error detail -> sandbox_failed detail
        | Ok seccomp_args ->
        match Keeper_sandbox_runtime.docker_network_args t.network_mode with
        | Error msg -> sandbox_failed msg
        | Ok (network_args, network_label) ->
        (match
           Keeper_sandbox_runtime.docker_user_identity_mount_args
             ~host_root:t.host_root
             ~uid:t.uid
             ~gid:t.gid
         with
         | Error detail -> sandbox_failed detail
         | Ok identity_mounts ->
         (match
            Keeper_secret_projection.docker_args_for_keeper
              ~base_path:t.config.base_path
              ~keeper_name:t.meta.name
              ~container_name
              ()
          with
          | Error err ->
            sandbox_failed ("docker_container_start_failed: secret_projection: " ^ err)
          | Ok secret_projection ->
           (match
              Keeper_github_identity.docker_args_persistent
                ~config:t.config
                ~keeper_name:t.meta.name
                ~container_masc_dir:
                  (Keeper_sandbox_runtime_setup.container_masc_dir
                     ~container_root:t.container_root)
            with
            | Error err ->
              Eio_guard.protect
                ~finally:secret_projection.cleanup
                (fun () ->
                   Error
                     (Identity_unavailable
                        ("docker_container_start_failed: github_identity_invalid: "
                         ^ err)))
            | Ok github_identity_args ->
            Eio_guard.protect
              ~finally:secret_projection.cleanup
              (fun () ->
              (* No [--rm]: the container outlives the turn, and auto-remove
                 on stop would destroy state a later turn expects to adopt.
                 Removal is the keeper's teardown, not the daemon's. *)
              Keeper_sandbox_runtime_setup.refuse_real_daemon_under_test
                ~what:"start a persistent container";
              let argv =
                Keeper_sandbox_runtime.docker_command_argv ()
                @ [ "run"; "-d"; "--name"; container_name ]
                @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
                @ Keeper_sandbox_runtime.docker_label_args
                    ~base_path:t.config.base_path
                    ~keeper_name:t.meta.name
                    ~container_kind:Keeper_sandbox_runtime.persistent_container_kind
                    ~network_label
                    ()
                @ [ "--user"; Printf.sprintf "%d:%d" t.uid t.gid ]
                @ Keeper_sandbox_runtime.docker_sandbox_env_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ Keeper_sandbox_runtime.docker_nofile_args ()
                @ Env_config_sandbox.Hardening.read_only_rootfs_args ()
                @ [ "--tmpfs"
                  ; Env_config_sandbox.Hardening.tmpfs_mount ()
                  ; "--cap-drop=ALL"
                  ; "--security-opt"
                  ; "no-new-privileges"
                  ]
                @ seccomp_args
                @ [ "--pids-limit"
                  ; string_of_int (Env_config_sandbox.Hardening.pids_limit ())
                  ; "--memory"
                  ; Env_config_sandbox.Hardening.memory ()
                  ; "-v"
                  ; t.host_root ^ ":" ^ t.container_root ^ ":rw"
                  ; "--workdir"
                  ; t.container_root
                  ]
                @ Keeper_sandbox_runtime.docker_config_mount_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ Keeper_sandbox_runtime.docker_workspace_state_mount_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ secret_projection.docker_args
                @ github_identity_args
                @ identity_mounts
                @ network_args
                @ [ image; "tail"; "-f"; "/dev/null" ]
              in
              let st, out = run_argv_with_status ?timeout_sec argv in
              match st with
              | Unix.WEXITED 0 ->
                (* The same probe the start began with. Listed in any state,
                   it is the container this run made. *)
                (match probe_state () with
                 | Ok
                     ( Keeper_sandbox_runtime.Docker_container_running
                     | Keeper_sandbox_runtime.Docker_container_stopped ) ->
                   set_state t (Running { container_name });
                   Ok container_name
                 | Ok Keeper_sandbox_runtime.Docker_container_absent ->
                   (* The daemon does not list the container its run reported.
                      t.state stays Not_started, so the name is removed here,
                      best effort, rather than left for nothing to reclaim. *)
                   let rm_argv =
                     Keeper_sandbox_runtime.docker_remove_argv container_name
                   in
                   let _rm_st, _rm_out =
                     run_argv_with_status ?timeout_sec rm_argv
                   in
                   sandbox_failed
                     (Printf.sprintf
                        "docker_container_absent_after_run: docker run exited 0 \
                         and the daemon does not list %s"
                        container_name)
                 | Error probe_error ->
                   (* The daemon could not be asked. The container this run
                      made may be up, so it is not removed: the next start
                      probes the stable name again and adopts it. *)
                   sandbox_failed
                     (Printf.sprintf
                        "docker_container_state_unknown_after_run: %s"
                        (Exec_policy.truncate_for_log probe_error)))
              | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
                (match probe_state () with
                 | Ok Keeper_sandbox_runtime.Docker_container_running ->
                   (* Another turn or server of this keeper booted the shared
                      name between the absent probe and this run; the run's
                      name loss is the winner's, and this call adopts the
                      winner. *)
                   adopt_running ()
                 | ( Ok
                       ( Keeper_sandbox_runtime.Docker_container_stopped
                       | Keeper_sandbox_runtime.Docker_container_absent )
                   | Error _ ) as container_state ->
                   sandbox_failed
                     (Keeper_sandbox_exec_failure.docker_run_failure_message
                        ~prefix:"docker_container_start_failed"
                        ~base_path_hash:
                          (Keeper_sandbox_runtime.base_path_hash t.config.base_path)
                        ~keeper_name:t.meta.name
                        ~container_kind:
                          Keeper_sandbox_runtime.persistent_container_kind
                        ~network_label:(network_mode_to_string t.network_mode)
                        ~image
                        ~status:st
                        ~container_state
                        ~output:out
                        ())))))))
  in
  match probe_state () with
  | Ok Keeper_sandbox_runtime.Docker_container_running -> adopt_running ()
  | Error probe_error ->
    sandbox_failed
      (Printf.sprintf
         "docker_container_probe_failed: %s"
         (Exec_policy.truncate_for_log probe_error))
  | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
    (* A stopped container keeps its filesystem layer: [docker start] resumes
       it instead of losing the installed state the persistence exists to
       keep. A start failure (image evicted from the daemon, mount source
       vanished) falls through to remove-and-recreate. *)
    let start_argv =
      Keeper_sandbox_runtime.docker_command_argv ()
      @ [ "start"; container_name ]
    in
    let start_st, _start_out =
      run_argv_with_status ?timeout_sec start_argv
    in
    if start_st = Unix.WEXITED 0
    then (
      match
        inspect_container_exists ?timeout_sec container_name
      with
      | Ok () -> adopt_running ()
      | Error inspect_out ->
        sandbox_failed
          (Printf.sprintf
             "docker_container_start_failed: restarted %s but inspect cannot \
              see it: %s"
             container_name
             (Exec_policy.truncate_for_log inspect_out)))
    else (
      let rm_argv =
        Keeper_sandbox_runtime.docker_remove_argv container_name
      in
      let _rm_st, _rm_out = run_argv_with_status ?timeout_sec rm_argv in
      create ())
  | Ok Keeper_sandbox_runtime.Docker_container_absent -> create ()
;;

let ensure_started_with_cause ?(validate_running = false) ?timeout_sec (t : t) =
  match get_state t with
  | Running { container_name } ->
    if not validate_running
    then Ok container_name
    else (
      (* Validation is asked for only by the Docker exec entrypoints, after
         [docker_exec_only] has refused a microvm runtime. *)
      match inspect_container_running ?timeout_sec container_name with
      | Ok () -> Ok container_name
      | Error _ ->
        set_state t Not_started;
        start_container ?timeout_sec t)
  | Not_started -> start_container ?timeout_sec t
;;

(* The exec entrypoints report every start failure as one message. Only the
   identity preparation reads which side failed. *)
let ensure_started ?validate_running ?timeout_sec (t : t) =
  Result.map_error github_identity_preparation_error_message
    (ensure_started_with_cause ?validate_running ?timeout_sec t)
;;

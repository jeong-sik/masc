(** Docker/sandbox shell execution infrastructure.

    Extracted from keeper_tool_command_runtime.ml — Docker container lifecycle,
    sandbox profile resolution, and container invocation functions.
    These are pure infrastructure; command dispatch remains in
    keeper_tool_command_runtime.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let process_status_is_success = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let path_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false
;;

let path_is_directory path =
  try Sys.is_directory path with
  | Sys_error _ -> false
;;

let docker_mount_preflight_details
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~image
      ~container_kind
      ~network_label
      ~mount_path
      ~reason
  =
  `Assoc
    [ "event", `String "keeper_docker_mount_preflight_failure"
    ; "mount_path", `String mount_path
    ; "base_path_hash", `String (Keeper_sandbox_runtime.base_path_hash config.base_path)
    ; "keeper", `String meta.name
    ; "image", `String image
    ; "container_kind", `String container_kind
    ; "network", `String network_label
    ; "reason", `String reason
    ]
;;

(* ── Container naming ──────────────────────────────────── *)

let keeper_sandbox_container_name =
  Keeper_sandbox_docker_container_name.keeper_sandbox_container_name
let keeper_private_container_root =
  Keeper_sandbox_docker_container_name.keeper_private_container_root
let docker_private_workspace_cwd =
  Keeper_sandbox_docker_container_name.docker_private_workspace_cwd

let rewrite_docker_command_paths ~(config : Workspace.config) ~(meta : keeper_meta) cmd =
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
      ~(config : Workspace.config)
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

(* Invariant: the declared sandbox profile is the execution contract. *)
let effective_sandbox_profile ~(meta : keeper_meta) =
  match meta.sandbox_profile with
  | Docker -> Docker, meta.network_mode
  | Local -> Local, meta.network_mode
;;

(* ── Sandbox runtime preflight ─────────────────────────── *)

let ensure_keeper_sandbox_runtime ~timeout_sec =
  Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec
;;

(* ── Docker invocation ─────────────────────────────────── *)

type docker_shell_result =
  { status : Unix.process_status
  ; output : string
  ; image : string
  ; network_label : string
  ; cwd : string
  }

(** Normalize a Docker invocation result into the common [(status, output)]
    pair used by shell-op handlers.  [Error] maps to a synthetic
    [WEXITED 127] so callers can treat both branches uniformly. *)
let docker_result_pair = function
  | Ok (result : docker_shell_result) -> result.status, result.output
  | Error msg -> Unix.WEXITED 127, msg
;;

(* docker run --rm wall-clock covers spawn + container
   cold start + actual cmd + drain. The floor is hardcoded at 20s because
   the hang modes (docker daemon stall, container start stall, command
   stall) are the same domain — the sandbox's own.  Caller does not
   observe this: the sandbox backend owns its hang protection rather than a
   caller-side product-specific timeout. *)

let resolve_sandbox_image (meta : keeper_meta) =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_sandbox.Runtime.docker_image ()
;;

let docker_cleanup_rm_timeout_sec () =
  Env_config_sandbox.Shell_timeout.timeout_sec
    ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
    ()
;;

let docker_oneshot_ttl_sec ~timeout_sec =
  timeout_sec +. docker_cleanup_rm_timeout_sec () +. 10.0
;;

type cleanup_target_state =
  | Cleanup_target_absent
  | Cleanup_target_present
  | Cleanup_target_state_unknown of string

let cleanup_target_state ~container_name =
  match
    Keeper_sandbox_runtime.probe_container_state
      ~container_name
      ~timeout_sec:(docker_cleanup_rm_timeout_sec ())
  with
  | Ok Keeper_sandbox_runtime.Docker_container_absent -> Cleanup_target_absent
  | Ok Keeper_sandbox_runtime.Docker_container_running
  | Ok Keeper_sandbox_runtime.Docker_container_stopped -> Cleanup_target_present
  | Error detail -> Cleanup_target_state_unknown detail
;;

let cleanup_oneshot_container ~container_name =
  let argv = Keeper_sandbox_runtime.docker_command_argv () @ [ "rm"; "-f"; container_name ] in
  let run_rm () =
    Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:(Masc_exec.Agent_id.of_string "system/sandbox")
        ~raw_source:(String.concat " " argv)
        ~summary:"keeper docker oneshot cleanup"
        ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
        ~cwd:(Config_dir_resolver.current_working_dir ())
        ~timeout_sec:(docker_cleanup_rm_timeout_sec ())
        argv)
  in
  let status, output = run_rm () in
  match status with
  | Unix.WEXITED 0 -> ()
  | _ ->
    let retry_after_failure ?probe_error () =
      (* The machine-oriented state probe is authoritative. Retry only while
         the target is still present or its state could not be established. *)
      (match probe_error with
       | None ->
          Log.Keeper.info
            "docker oneshot cleanup for %s failed (status=%s), retrying once"
            container_name
            (Keeper_sandbox_exec_failure.status_label status)
       | Some probe_error ->
          Log.Keeper.warn
            "docker oneshot cleanup state probe failed for %s after rm status=%s: %s; \
             retrying once"
            container_name
            (Keeper_sandbox_exec_failure.status_label status)
            probe_error);
      let retry_status, retry_output = run_rm () in
      match retry_status with
      | Unix.WEXITED 0 -> ()
      | _ ->
        (match cleanup_target_state ~container_name with
         | Cleanup_target_absent -> ()
         | Cleanup_target_present ->
           Log.Keeper.warn
             "docker oneshot cleanup failed for %s after retry (status=%s, output=%s)"
             container_name
             (Keeper_sandbox_exec_failure.status_label retry_status)
             (Exec_policy.truncate_for_log retry_output)
         | Cleanup_target_state_unknown probe_error ->
           Log.Keeper.warn
             "docker oneshot cleanup failed for %s after retry (status=%s, output=%s, \
              state_probe_error=%s)"
             container_name
             (Keeper_sandbox_exec_failure.status_label retry_status)
             (Exec_policy.truncate_for_log retry_output)
             probe_error)
    in
    (match cleanup_target_state ~container_name with
     | Cleanup_target_absent -> ()
     | Cleanup_target_present -> retry_after_failure ()
     | Cleanup_target_state_unknown probe_error ->
       retry_after_failure ~probe_error ())
;;

let ensure_docker_shell_image_available ~image ~timeout_sec =
  match
    Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class
      ~image
      ~timeout_sec
  with
  | Ok () -> Ok ()
  | Error failure ->
    Error
      (Keeper_sandbox_runtime.docker_image_preflight_failure_message
         ~prefix:"docker_shell_failed"
         failure)
;;

type docker_mount_check_error =
  | Mount_source_not_found of string
  | Mount_source_not_directory of string
  | Cwd_not_found of string
  | Cwd_not_directory of string

let check_docker_mounts ~host_root ~cwd =
  if not (path_exists host_root)
  then Error (Mount_source_not_found host_root)
  else if not (path_is_directory host_root)
  then Error (Mount_source_not_directory host_root)
  else if not (path_exists cwd)
  then Error (Cwd_not_found cwd)
  else if not (path_is_directory cwd)
  then Error (Cwd_not_directory cwd)
  else Ok ()
;;

let docker_run_argv
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~container_name
      ~container_root
      ~container_cwd
      ~host_root
      ~network_label
      ~network_args
      ~uid
      ~gid
      ~seccomp_args
      ~identity_mounts
      ~secret_args
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
  @ Keeper_sandbox_runtime.docker_sandbox_env_args ~base_path:config.base_path ~container_root
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
    ; host_root ^ ":" ^ container_root ^ ":rw"
    ; "--workdir"
    ; container_cwd
    ]
  @ Keeper_sandbox_runtime.docker_config_mount_args
      ~base_path:config.base_path
      ~container_root
  @ Keeper_sandbox_runtime.docker_workspace_state_mount_args
      ~base_path:config.base_path
      ~container_root
  @ secret_args
  @ network_args
  @ identity_mounts
  @ [ image; "bash"; "-l"; "-s" ]
;;

let optional_ro_mount ~host ~container =
  if host = ""
  then []
  else if not (Sys.file_exists host)
  then
    (* Log the skipped mount so operators can distinguish "mount
       deliberately omitted" from "mount expected but path missing"
       when debugging container-internal file access failures. *)
    ( Log.Keeper.debug
        "optional_ro_mount skipped: host path %S does not exist (container=%S)"
        host
        container
    ; [] )
  else [ "-v"; host ^ ":" ^ container ^ ":ro" ]
;;

let sandbox_error_json ~(config : Workspace.config) ~(meta : keeper_meta) message =
  Keeper_registry_error_recording.record ~base_path:config.base_path meta.name message;
  error_json message
;;

let sandbox_error ~(config : Workspace.config) ~(meta : keeper_meta) ?details message =
  Keeper_registry_error_recording.record ?details ~base_path:config.base_path meta.name message;
  Error message
;;

(** Shared by [run_docker_bash] and [run_docker_shell_command_with_status_internal]:
    parse cmd and validate its paths. Returns [Ok cwd] when every objective
    containment check passes.

    [validate_command_paths] toggles the host-side path validation gate
    (default [true]).  Callers that already validated paths (e.g. trusted
    internal dispatch) may pass [false]. *)
let validate_docker_dispatch_context
      ?(validate_command_paths = true)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(cmd : string)
      ()
  =
  match Exec_policy.parse_string_to_ir ~mode:Tool_execute cmd with
  | Error reason ->
    Error
      (Printf.sprintf
         "sandbox_profile=docker blocked unsupported shell command shape: %s \
          [blocked_cmd=%s]"
         (Exec_policy.block_reason_to_string reason)
         cmd)
  | Ok _cmd_ir ->
    let path_validation =
      if validate_command_paths
      then (
        let validation_cmd =
          rewrite_docker_command_paths_for_host_validation ~config ~meta cmd
        in
        match Exec_policy.parse_string_to_ir ~mode:Tool_execute validation_cmd with
        | Ok validation_ir ->
          Keeper_tool_execute_shell_ir.validate_paths
            ~workdir:cwd
            validation_ir
        | Error reason ->
          Error
            (Printf.sprintf
               "sandbox_profile=docker blocked unsupported shell command shape after \
                host path rewrite: %s"
               (Exec_policy.block_reason_to_string reason)))
      else Ok ()
    in
    match path_validation with
    | Error err -> Error (Printf.sprintf "%s [blocked_cmd=%s]" err cmd)
    | Ok () -> Ok cwd
;;

let run_docker_shell_command_with_status_internal
      ~validate_command_paths
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(timeout_sec : float)
      ~(cmd : string)
      ~(network_mode : network_mode)
  =
  let image = resolve_sandbox_image meta in
  let sandbox_error = sandbox_error ~config ~meta in
  if String.trim image = ""
  then sandbox_error "keeper sandbox docker image is not configured"
  else (
    let cmd = rewrite_docker_command_paths ~config ~meta cmd in
    match
        validate_docker_dispatch_context
          ~validate_command_paths
          ~config
          ~meta
          ~cwd
          ~cmd
          ()
      with
      | Error msg -> sandbox_error msg
      | Ok cwd ->
        let host_root =
          Keeper_sandbox.host_root_abs_of_meta ~config meta
          |> Keeper_alerting_path.normalize_path_for_check
          |> Keeper_alerting_path.strip_trailing_slashes
        in
        let container_name = keeper_sandbox_container_name meta in
              let container_root = keeper_private_container_root meta in
              let container_cwd = docker_private_workspace_cwd ~config ~meta cwd in
              let network_args, network_label =
                Keeper_sandbox_runtime.docker_network_args network_mode
              in
              let mount_preflight_error ~reason ~detail_msg mount_path =
                let details =
                  docker_mount_preflight_details
                    ~config
                    ~meta
                    ~image
                    ~container_kind:"oneshot"
                    ~network_label
                    ~mount_path
                    ~reason
                in
                sandbox_error
                  ~details
                  (Printf.sprintf
                     "docker_shell_failed: %s: mount_path=%S \
                      base_path_hash=%S keeper=%S image=%S container_kind=%S \
                      network=%S (%s)"
                     reason
                     mount_path
                     (Keeper_sandbox_runtime.base_path_hash config.base_path)
                     meta.name
                     image
                     "oneshot"
                     network_label
                     detail_msg)
              in
              (* Pre-flight: verify the bind source and host cwd before spawning a
                 container. Missing bind sources otherwise fail inside Docker
                 Desktop as opaque OCI mount errors and can degrade the daemon. *)
              (match check_docker_mounts ~host_root ~cwd with
              | Error (Mount_source_not_found mount_path) ->
                mount_preflight_error
                  ~reason:"mount_source_not_found"
                  ~detail_msg:"host bind mount source does not exist; repair the sandbox playground before docker run"
                  mount_path
              | Error (Mount_source_not_directory mount_path) ->
                mount_preflight_error
                  ~reason:"mount_source_not_directory"
                  ~detail_msg:"host bind mount source must be a directory"
                  mount_path
              | Error (Cwd_not_found cwd) ->
                sandbox_error
                  (Printf.sprintf
                     "docker_shell_failed: cwd_not_found: %s (host working directory \
                      does not exist; verify the relative path under your playground \
                     before calling the structured file/search tool)"
                     cwd)
              | Error (Cwd_not_directory cwd) ->
                sandbox_error
                  (Printf.sprintf
                     "docker_shell_failed: cwd_not_directory: %s (working directory must \
                      be a directory, not a file)"
                     cwd)
              | Ok () -> (
                let _cleanup =
                  Keeper_sandbox_runtime.maybe_cleanup_stale_containers
                    ~base_path:config.base_path
                    ~timeout_sec
                    ()
                in
                match ensure_keeper_sandbox_runtime ~timeout_sec with
                | Error err -> sandbox_error err
                | Ok seccomp_args ->
                  (match ensure_docker_shell_image_available ~image ~timeout_sec with
                   | Error err -> sandbox_error err
                   | Ok () ->
                     let uid = Unix.getuid () in
                     let gid = Unix.getgid () in
                     match
                       Keeper_sandbox_runtime.docker_user_identity_mount_args
                         ~host_root
                         ~uid
                         ~gid
                     with
                     | Error err -> sandbox_error err
                     | Ok identity_mounts ->
                       (match
                          Keeper_secret_projection.docker_args_for_keeper
                            ~base_path:config.base_path
                            ~keeper_name:meta.name
                            ~container_name
                            ()
                        with
                        | Error err ->
                          sandbox_error ("docker_shell_failed: secret_projection: " ^ err)
                        | Ok secret_projection ->
                          let argv =
                            docker_run_argv
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
                              ~identity_mounts
                              ~secret_args:secret_projection.docker_args
                              ~image
                              ~ttl_sec:(docker_oneshot_ttl_sec ~timeout_sec)
                          in
                          (try
                             let run_once () =
                               Keeper_turn_sandbox_runtime.run_argv_with_stdin_and_status_split
                                 ~timeout_sec
                                 ~stdin_content:cmd
                                 argv
                             in
                             Eio_guard.protect
                               ~finally:(fun () -> secret_projection.cleanup ())
                               (fun () ->
                                  let status, stdout, stderr =
                                    Eio_guard.protect
                                      ~finally:(fun () ->
                                        cleanup_oneshot_container ~container_name)
                                      (fun () -> run_once ())
                                  in
                                  let output =
                                    match stdout, stderr with
                                    | "", err -> err
                                    | out, "" -> out
                                    | out, err -> out ^ "\n" ^ err
                                  in
                                  let ok = process_status_is_success status in
                                  if not ok
                                  then
                                    Keeper_sandbox_exec_failure.record_docker_failure
                                      ~config
                                      ~meta
                                      ~image
                                      ~container_kind:"oneshot"
                                      ~network_label
                                      ~status
                                      ~output
                                  else
                                    Keeper_registry.clear_error
                                      ~base_path:config.base_path
                                      meta.name;
                                  Ok
                                    { status
                                    ; output
                                    ; image
                                    ; network_label
                                    ; cwd
                                    })
                           with
                           | Eio.Cancel.Cancelled _ as exn -> raise exn
                           | Failure err -> sandbox_error err
                           | Sys_error err ->
                             sandbox_error
                               (Printf.sprintf "docker_shell_failed: sys_error: %s" err)
                           | Unix.Unix_error (code, fn, arg) ->
                             sandbox_error
                               (Printf.sprintf
                                  "docker_shell_failed: unix_error: %s: %s(%s)"
                                  (Unix.error_message code)
                                  fn
                                  arg)))))))
;;

let run_docker_shell_command_with_status =
  run_docker_shell_command_with_status_internal ~validate_command_paths:true
;;

let run_trusted_docker_shell_command_with_status =
  run_docker_shell_command_with_status_internal ~validate_command_paths:false
;;

(** Preflight shared by [run_docker_bash]. Command meaning is deliberately
    opaque here; socket, mount, network, and path containment are enforced by
    the sandbox itself. *)
let docker_bash_preflight ~config ~meta ~cmd:_ =
  let image = resolve_sandbox_image meta in
  let sandbox_error_json = sandbox_error_json ~config ~meta in
  if String.trim image = ""
  then Some (sandbox_error_json "keeper sandbox docker image is not configured")
  else None
;;

let docker_bash_response ~ok ~network_label ~status ~output ~cwd_response
  =
  Yojson.Safe.to_string
    (`Assoc
	       ([ "ok", `Bool ok
	         ; "via", `String "docker"
	         ; "cwd", Keeper_cwd_response.to_yojson_response cwd_response
	         ; "sandbox_profile", `String "docker"
	         ; "network_mode", `String network_label
	         ; "status", Keeper_alerting_path.process_status_to_json status
	         ]
         @ [ "output", `String output ]))

(** Convert a [docker_shell_result] into the JSON response string
    shared by container-backed bash paths. *)
let docker_result_to_bash_response ~config ~meta result =
  let cwd_response =
    Keeper_cwd_response.of_sandbox
      ~sandbox:(Keeper_sandbox.of_meta ~config ~meta)
      ~host_cwd:result.cwd
      ~container_cwd_for_docker:
        (docker_private_workspace_cwd ~config ~meta result.cwd)
  in
  docker_bash_response
    ~ok:(process_status_is_success result.status)
    ~network_label:result.network_label
    ~status:result.status
    ~output:result.output
    ~cwd_response
;;

(** Shared container-backed bash execution:
    [run_docker_shell_command_with_status] → response JSON.
    Used by [run_docker_bash]. *)
let run_docker_bash_via_container
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(timeout_sec : float)
      ~(cmd : string)
      ~(network_mode : network_mode)
  =
  match
    run_docker_shell_command_with_status
      ~config ~meta ~cwd ~timeout_sec ~cmd ~network_mode
  with
  | Error message -> error_json message
  | Ok result ->
    docker_result_to_bash_response ~config ~meta result
;;

let run_docker_bash
      ~(turn_sandbox_runtime : Keeper_turn_sandbox_runtime.t option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(timeout_sec : float)
      ~(cmd : string)
      ~(network_mode : network_mode)
  =
  let image = resolve_sandbox_image meta in
  let sandbox_error_json = sandbox_error_json ~config ~meta in
  match docker_bash_preflight ~config ~meta ~cmd with
  | Some err -> err
  | None -> (
    match turn_sandbox_runtime, network_mode with
    | Some runtime, Network_none ->
      (match validate_docker_dispatch_context ~config ~meta ~cwd ~cmd () with
       | Error message -> sandbox_error_json message
       | Ok cwd ->
         (match
            Keeper_turn_sandbox_runtime.run_bash_with_status
              runtime
              ~timeout_sec
              ~cwd
              ~cmd
              ()
          with
          | Error message -> sandbox_error_json message
          | Ok (st, out) ->
            let ok = process_status_is_success st in
            if not ok
            then
              Keeper_sandbox_exec_failure.record_docker_failure
                ~config
                ~meta
                ~image
                ~container_kind:"turn"
                ~network_label:(network_mode_to_string network_mode)
                ~status:st
                ~output:out
            else Keeper_registry.clear_error ~base_path:config.base_path meta.name;
            let cwd_response =
              Keeper_cwd_response.of_sandbox
                ~sandbox:(Keeper_sandbox.of_meta ~config ~meta)
                ~host_cwd:cwd
                ~container_cwd_for_docker:
                  (Keeper_turn_sandbox_runtime.container_cwd_of_host
                     runtime
                     ~host_cwd:cwd)
            in
	     docker_bash_response
		       ~ok
	      ~network_label:(network_mode_to_string network_mode)
              ~status:st
              ~output:out
              ~cwd_response
              ))
    | _ ->
      (match turn_sandbox_runtime with
       | Some _ ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string DockerRuntimeDiscarded)
           ~labels:[ "keeper", meta.name; "reason", "network_mode_mismatch" ]
           ()
       | None -> ());
	     run_docker_bash_via_container
	       ~config ~meta ~cwd ~timeout_sec ~cmd
	      ~network_mode)
;;

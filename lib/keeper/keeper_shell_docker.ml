(** Docker/sandbox shell execution infrastructure.

    Extracted from keeper_exec_shell.ml — Docker container lifecycle,
    sandbox profile resolution, and container invocation functions.
    These are pure infrastructure; command dispatch remains in
    keeper_exec_shell.ml. *)

open Keeper_types
open Keeper_exec_shared

include Keeper_shell_docker_preflight
include Keeper_shell_docker_lifecycle

include Keeper_shell_docker_path_rewrite
include Keeper_shell_docker_profile
include Keeper_shell_docker_semantic
include Keeper_shell_docker_mount_check
include Keeper_shell_docker_credential
include Keeper_shell_docker_argv

(* ── Container naming ──────────────────────────────────── *)

let keeper_sandbox_container_name =
  Keeper_shell_docker_container_name.keeper_sandbox_container_name
let keeper_private_container_root =
  Keeper_shell_docker_container_name.keeper_private_container_root
let docker_private_workspace_cwd =
  Keeper_shell_docker_container_name.docker_private_workspace_cwd

(* ── Profile resolution ────────────────────────────────── *)

(* ── Nested runtime detection ──────────────────────────── *)
include Keeper_shell_docker_nested_runtime

(* ── Sandbox runtime preflight ─────────────────────────── *)

let ensure_keeper_sandbox_runtime ~timeout_sec =
  Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec
;;


(* Container worktree gitdir path rewriter extracted to
   [Keeper_shell_docker_worktree_gitdir] (godfile decomp). *)
let container_worktree_gitdir_candidates = Keeper_shell_docker_worktree_gitdir.candidates
let repair_container_worktree_gitdirs = Keeper_shell_docker_worktree_gitdir.repair
let prepare_container_worktree_gitdirs = Keeper_shell_docker_worktree_gitdir.prepare

(* ── Docker invocation ─────────────────────────────────── *)

type docker_shell_result =
  { status : Unix.process_status
  ; output : string
  ; image : string
  ; network_label : string
  }

(* docker run --rm wall-clock covers slot_wait + spawn + container
   cold start + actual cmd + drain. A 5s floor was insufficient under
   typical conditions — trivial commands such as [git -C ... status]
   were timing out at 5s because the cold-start path alone (image pull
   + container creation + shell init) can take 10-60s on a cold host.

   #8688 raised the gh-cli floor to [gh_min_timeout_sec = 15s] for the
   same class of failure (sub-network-latency timeouts cascading into
   401 retries); the docker path was left at 5s — an N-of-M between
   sibling timeout floors. This restores parity (15s gh + 5s headroom
   for container creation) and exposes an env override so operators
   can tune for slow-pull fleets without rebuilding.

   This minimum applies only to the [docker run] path, not to
   [docker exec] against a warm container. *)

let resolve_sandbox_image meta =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
;;

let nested_runtime_blocker ~git_creds_enabled =
  if git_creds_enabled
  then
    "sandbox_profile=docker+git_creds blocks nested container runtimes and host socket \
     references"
  else
    "sandbox_profile=docker blocks nested container runtimes and host socket references"
;;

let run_docker_shell_command_with_status_internal
      ~validate_command_paths
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(timeout_sec : float)
      ~(cmd : string)
      ~(git_creds_enabled : bool)
      ~(network_mode : network_mode)
  =
  let timeout_sec = max timeout_sec docker_run_min_timeout_sec in
  let image = resolve_sandbox_image meta in
  let sandbox_error ?details message =
    Keeper_registry_error_recording.record ?details ~base_path:config.base_path meta.name message;
    Error message
  in
  if String.trim image = ""
  then sandbox_error "keeper sandbox docker image is not configured"
  else (
    let cmd = rewrite_docker_command_paths ~config ~meta cmd in
    if command_uses_nested_container_runtime cmd
    then sandbox_error (nested_runtime_blocker ~git_creds_enabled)
    else
      let cmd_stages =
        match Masc_exec_command_gate.Shell_command_gate.parse_to_ir_opt cmd with
        | Some ir -> Keeper_shell_command_semantics.effective_stages_of_ir ir
        | None -> []
      in
      let cwd, multi_repo_blocker =
        Keeper_shell_command_semantics.resolve_sandbox_root_git_cwd_of_stages
          ~config ~meta ~cwd ~cmd cmd_stages
      in
      match multi_repo_blocker with
      | Some msg -> sandbox_error msg
      | None ->
      let path_validation =
        if validate_command_paths
        then
          let validation_cmd =
            rewrite_docker_command_paths_for_host_validation ~config ~meta cmd
          in
          (match Masc_exec_command_gate.Shell_command_gate.parse_to_ir_opt validation_cmd with
           | Some validation_ir ->
             (match
                Keeper_task_worktree_lazy.ensure_shell_ir_existing_dirs
                  ~config ~meta ~cwd ~ir:validation_ir
              with
              | Error e -> Error e
              | Ok () ->
                Exec_policy.validate_shell_ir_paths
                  ~keeper_id:meta.name
                  ~base_path:(Keeper_alerting_path.project_root_of_config config)
                  ~workdir:cwd
                  validation_ir)
           | None -> Ok ())
        else Ok ()
      in
      match path_validation with
      | Error err -> sandbox_error (Printf.sprintf "%s [blocked_cmd=%s]" err cmd)
      | Ok () ->
      (match fd_admission_error ~config with
       | Some err -> sandbox_error err
       | None ->
        let host_root =
          Keeper_sandbox.host_root_abs_of_meta ~config meta
          |> Keeper_alerting_path.normalize_path_for_check
          |> Keeper_alerting_path.strip_trailing_slashes
        in
        (* #10424: keeper LLM이 sandbox root에서 cd 없이 git/gh 호출 시
         "fatal: not a git repository" 발생. mount point는 git repo 아니고
         repos/<repo>/ 안에만 git checkout 존재. filesystem ground truth
         (repos/ enumeration)로 결정론적 분기:
         - single-repo → 자동 chdir (silent)
         - multi-repo → explicit error로 LLM이 정확한 경로 학습
         - 0 repo → explicit error로 clone/cwd 복구 액션 학습 *)
        (* #10855: surface gh syntax misuse before docker exec so the LLM
         sees a corrected-form hint in the same turn rather than gh's raw
         "unknown flag: --repo" error after the round-trip. *)
           (match
              Keeper_shell_command_semantics.detect_gh_repo_flag_with_api_misuse_of_stages
                cmd_stages
            with
            | Some (repo_arg, endpoint) ->
              sandbox_error
                (Printf.sprintf
                   "잘못된 gh syntax: 'gh --repo %s api %s ...' — '--repo' 는 subcommand \
                    flag (gh issue/pr/release/run) 전용이고 'gh api' 에는 적용 안 됨. 올바른 형태: 'gh \
                    api repos/%s/%s' (endpoint 안에 org/repo 포함). 다음 turn 에서 cmd 를 수정하세요."
                   repo_arg
                   endpoint
                   repo_arg
                   endpoint)
            | None ->
              let container_name = keeper_sandbox_container_name meta in
              let container_root = keeper_private_container_root meta in
              let container_cwd = docker_private_workspace_cwd ~config ~meta cwd in
              let network_args, network_label =
                if git_creds_enabled
                then [ "--network"; "bridge" ], "bridge"
                else Keeper_sandbox_runtime.docker_network_args network_mode
              in
              (* Pre-flight: verify the bind source and host cwd before spawning a
                 container. Missing bind sources otherwise fail inside Docker
                 Desktop as opaque OCI mount errors and can degrade the daemon. *)
              (match Keeper_shell_docker_mount_check.check ~host_root ~cwd with
              | Error (Mount_source_not_found mount_path) ->
                let details =
                  docker_mount_preflight_details
                    ~config
                    ~meta
                    ~image
                    ~container_kind:"oneshot"
                    ~network_label
                    ~mount_path
                    ~reason:"mount_source_not_found"
                in
                sandbox_error
                  ~details
                  (Printf.sprintf
                     "docker_shell_failed: mount_source_not_found: mount_path=%S \
                      base_path_hash=%S keeper=%S image=%S container_kind=%S \
                      network=%S (host bind mount source does not exist; repair \
                      the sandbox playground before docker run)"
                     mount_path
                     (Keeper_sandbox_runtime.base_path_hash config.base_path)
                     meta.name
                     image
                     "oneshot"
                     network_label)
              | Error (Mount_source_not_directory mount_path) ->
                let details =
                  docker_mount_preflight_details
                    ~config
                    ~meta
                    ~image
                    ~container_kind:"oneshot"
                    ~network_label
                    ~mount_path
                    ~reason:"mount_source_not_directory"
                in
                sandbox_error
                  ~details
                  (Printf.sprintf
                     "docker_shell_failed: mount_source_not_directory: mount_path=%S \
                      base_path_hash=%S keeper=%S image=%S container_kind=%S \
                      network=%S (host bind mount source must be a directory)"
                     mount_path
                     (Keeper_sandbox_runtime.base_path_hash config.base_path)
                     meta.name
                     image
                     "oneshot"
                     network_label)
              | Error (Cwd_not_found cwd) ->
                sandbox_error
                  (Printf.sprintf
                     "docker_shell_failed: cwd_not_found: %s (host working directory \
                      does not exist; verify the relative path under your playground \
                     before calling keeper_shell)"
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
                    ~timeout_sec:
                      (Env_config_exec_timeout.timeout_sec ~caller:Sandbox ())
                    ()
                in
                match ensure_keeper_sandbox_runtime ~timeout_sec with
                | Error err -> sandbox_error err
                | Ok seccomp_args ->
                  (match ensure_docker_shell_image_available ~image ~timeout_sec with
                   | Error err -> sandbox_error err
                   | Ok () ->
                     let prepared_gitdirs =
                       Keeper_shell_docker_worktree_gitdir.prepare_conditional
                         ~git_creds_enabled ~cmd ~host_root ~container_root
                         ~keeper_name:meta.name
                     in
                     let restore_gitdirs () =
                       Keeper_shell_docker_worktree_gitdir.restore_and_log
                         ~git_creds_enabled ~host_root ~container_root
                         ~keeper_name:meta.name
                     in
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
                       match
                         Keeper_shell_docker_credential.resolve
                           ~config ~meta ~git_creds_enabled
                       with
                       | Error err -> sandbox_error err
                       | Ok (cred_mounts, cred_envs) ->
                          let argv =
                            Keeper_shell_docker_argv.docker_run_argv
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
                              ~ttl_sec:(docker_oneshot_ttl_sec ~timeout_sec)
                          in
                          (try
                             let status, output =
                               Eio_guard.protect
                                 ~finally:(fun () ->
                                   cleanup_oneshot_container ~container_name;
                                   restore_gitdirs ())
                               @@ fun () ->
                               Docker_spawn_throttle.with_slot (fun () ->
                                 Masc_exec.Exec_gate.run_argv_with_stdin_and_status
                                   ~actor:`Keeper_shell
                                   ~raw_source:(String.concat " " argv)
                                   ~summary:"keeper docker command"
                                   ~env:(Unix.environment ())
                                   ~cwd:(Sys.getcwd ())
                                   ~timeout_sec
                                   ~stdin_content:cmd
                                   argv)
                             in
                             if not (docker_command_semantic_success ~cmd ~status ~output)
                             then
                               record_docker_exec_failure
                                 ~config
                                 ~meta
                                 ~image
                                 ~container_kind:"oneshot"
                                 ~network_label
                                 ~status
                                 ~output
                             else if
                               git_creds_enabled
                               && String_util.contains_substring_ci cmd "git worktree"
                             then (
                               let repaired =
                                 repair_container_worktree_gitdirs ~host_root ~container_root
                               in
                               if repaired > 0
                               then
                                 Log.Keeper.info
                                   "%s: repaired %d docker worktree gitdir path(s) under %s"
                                   meta.name
                                   repaired
                                   host_root;
                               Keeper_registry.clear_error
                                 ~base_path:config.base_path
                                 meta.name);
                             Ok { status; output; image; network_label }
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
                                  arg))))))))
;;

let run_docker_shell_command_with_status =
  run_docker_shell_command_with_status_internal ~validate_command_paths:true
;;

let run_trusted_docker_shell_command_with_status =
  run_docker_shell_command_with_status_internal ~validate_command_paths:false
;;

let run_docker_credentialed_bash
      ~(turn_sandbox_runtime : Keeper_turn_sandbox_runtime.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(timeout_sec : float)
      ~(cmd : string)
      ()
  =
  let image = resolve_sandbox_image meta in
  let sandbox_error_json message =
    Keeper_registry_error_recording.record ~base_path:config.base_path meta.name message;
    error_json message
  in
  if String.trim image = ""
  then sandbox_error_json "keeper sandbox docker image is not configured"
  else if command_uses_nested_container_runtime cmd
  then sandbox_error_json (nested_runtime_blocker ~git_creds_enabled:true)
  else (
    (* P12: check egress policy for git commands with network access *)
    match check_egress ~config ~meta ~cmd with
    | Some blocked_json -> blocked_json
    | None ->
      let cmd_stages =
        match Masc_exec_command_gate.Shell_command_gate.parse_to_ir_opt cmd with
        | Some ir -> Keeper_shell_command_semantics.effective_stages_of_ir ir
        | None -> []
      in
      let cwd, sandbox_root_git_blocker =
        Keeper_shell_command_semantics.resolve_sandbox_root_git_cwd_of_stages
          ~config ~meta ~cwd ~cmd cmd_stages
      in
      (match sandbox_root_git_blocker with
       | Some message -> sandbox_error_json message
       | None ->
         let validation_cmd =
           rewrite_docker_command_paths_for_host_validation ~config ~meta cmd
         in
         let path_validation =
           match Masc_exec_command_gate.Shell_command_gate.parse_to_ir_opt validation_cmd with
           | Some validation_ir ->
             (match
                Keeper_task_worktree_lazy.ensure_shell_ir_existing_dirs
                  ~config ~meta ~cwd ~ir:validation_ir
              with
              | Error e -> Error e
              | Ok () ->
                Exec_policy.validate_shell_ir_paths
                  ~keeper_id:meta.name
                  ~base_path:(Keeper_alerting_path.project_root_of_config config)
                  ~workdir:cwd
                  validation_ir)
           | None -> Ok ()
         in
         (match path_validation with
          | Error err -> sandbox_error_json (Printf.sprintf "%s [blocked_cmd=%s]" err validation_cmd)
          | Ok () ->
           let _ = turn_sandbox_runtime in
           (match
              run_docker_shell_command_with_status
                ~config
                ~meta
                ~cwd
                ~timeout_sec
                ~cmd
                ~git_creds_enabled:true
                ~network_mode:Network_inherit
            with
            | Error message when is_credential_preflight_failure message ->
              credential_preflight_failure_json ~keeper_name:meta.name ~message
            | Error message -> error_json message
            | Ok result ->
              let cwd_response =
                Keeper_cwd_response.docker
                  ~host_cwd:cwd
                  ~container_cwd:(docker_private_workspace_cwd ~config ~meta cwd)
              in
              Yojson.Safe.to_string
                (`Assoc
                    ([ "ok", `Bool (result.status = Unix.WEXITED 0)
                     ; "via", `String "docker"
                     ; "cwd", Keeper_cwd_response.to_yojson_response cwd_response
                     ; "sandbox_profile", `String "docker"
                     ; "git_creds_enabled", `Bool true
                     ; "network_mode", `String result.network_label
                     ; "effective_sandbox_image", `String result.image
                     ; "status", Keeper_alerting_path.process_status_to_json result.status
                     ; "output", `String result.output
                     ]
                     @ gh_exit_class_field
                         ~stages:cmd_stages
                         ~status:result.status
                         ~output:result.output))))))
;;

let run_docker_bash
      ~(turn_sandbox_runtime : Keeper_turn_sandbox_runtime.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(timeout_sec : float)
      ~(cmd : string)
      ~(network_mode : network_mode)
  =
  let image =
    match meta.sandbox_image with
    | Some img when String.trim img <> "" -> img
    | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
  in
  let sandbox_error_json message =
    Keeper_registry_error_recording.record ~base_path:config.base_path meta.name message;
    error_json message
  in
  if String.trim image = ""
  then sandbox_error_json "keeper sandbox docker image is not configured"
  else if command_uses_nested_container_runtime cmd
  then
    sandbox_error_json
      "sandbox_profile=docker blocks nested container runtimes and host socket references"
  else (
    let cmd_stages =
      match Masc_exec_command_gate.Shell_command_gate.parse_to_ir_opt cmd with
      | Some ir -> Keeper_shell_command_semantics.effective_stages_of_ir ir
      | None -> []
    in
    let cwd, sandbox_root_git_blocker =
      Keeper_shell_command_semantics.resolve_sandbox_root_git_cwd_of_stages
        ~config ~meta ~cwd ~cmd cmd_stages
    in
    match sandbox_root_git_blocker with
    | Some message -> sandbox_error_json message
    | None ->
      let validation_cmd =
        rewrite_docker_command_paths_for_host_validation ~config ~meta cmd
      in
      let path_validation =
        match Masc_exec_command_gate.Shell_command_gate.parse_to_ir_opt validation_cmd with
        | Some validation_ir ->
          (match
             Keeper_task_worktree_lazy.ensure_shell_ir_existing_dirs
               ~config ~meta ~cwd ~ir:validation_ir
           with
           | Error e -> Error e
           | Ok () ->
             Exec_policy.validate_shell_ir_paths
               ~keeper_id:meta.name
               ~base_path:(Keeper_alerting_path.project_root_of_config config)
               ~workdir:cwd
               validation_ir)
        | None -> Ok ()
      in
      (match path_validation with
       | Error err -> sandbox_error_json (Printf.sprintf "%s [blocked_cmd=%s]" err validation_cmd)
       | Ok () ->
      (match turn_sandbox_runtime, network_mode with
       | Some runtime, Network_none ->
         (match
            Keeper_turn_sandbox_runtime.run_bash_with_status
              runtime
              ~cwd
              ~cmd
              ~timeout_sec
              ()
          with
          | Error message -> sandbox_error_json message
          | Ok (st, out) ->
            let semantic_status = docker_command_semantic_status ~cmd ~status:st ~output:out in
            let semantic_ok =
              docker_command_semantic_success ~cmd ~status:st ~output:out
            in
            if not semantic_ok
            then
              record_docker_exec_failure
                ~config
                ~meta
                ~image
                ~container_kind:"turn"
                ~network_label:(network_mode_to_string network_mode)
                ~status:st
                ~output:out
            else Keeper_registry.clear_error ~base_path:config.base_path meta.name;
            let cwd_response =
              Keeper_cwd_response.docker
                ~host_cwd:cwd
                ~container_cwd:
                  (Keeper_turn_sandbox_runtime.container_cwd_of_host
                     runtime
                     ~host_cwd:cwd)
            in
            Yojson.Safe.to_string
              (`Assoc
                  ([ "ok", `Bool semantic_ok
                   ; "via", `String "docker"
                   ; "cwd", Keeper_cwd_response.to_yojson_response cwd_response
                   ; "sandbox_profile", `String "docker"
                   ; "git_creds_enabled", `Bool false
                   ; "network_mode", `String (network_mode_to_string network_mode)
                   ; "effective_sandbox_image", `String image
                   ; "status", Keeper_alerting_path.process_status_to_json st
                   ; "semantic_status"
                     , `String (Exec_core.string_of_semantic_status semantic_status)
                   ; "output", `String out
                   ]
                   @ gh_exit_class_field ~stages:cmd_stages ~status:st ~output:out)))
       | _ ->
         (match turn_sandbox_runtime with
          | Some _ ->
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_docker_runtime_discarded
              ~labels:[ "keeper", meta.name; "reason", "network_mode_mismatch" ]
              ()
          | None -> ());
         (* P12: check egress policy before running networked container *)
         (match check_egress ~config ~meta ~cmd with
          | Some blocked_json -> blocked_json
          | None ->
            (match
               run_docker_shell_command_with_status
                 ~config
                 ~meta
                 ~cwd
                 ~timeout_sec
                 ~cmd
                 ~git_creds_enabled:false
                 ~network_mode
             with
             | Error message -> error_json message
             | Ok result ->
               let semantic_status =
                 docker_command_semantic_status
                   ~cmd
                   ~status:result.status
                   ~output:result.output
               in
               let semantic_ok =
                 docker_command_semantic_success
                   ~cmd
                   ~status:result.status
                   ~output:result.output
               in
               let cwd_response =
                 Keeper_cwd_response.docker
                   ~host_cwd:cwd
                   ~container_cwd:(docker_private_workspace_cwd ~config ~meta cwd)
               in
               Yojson.Safe.to_string
                 (`Assoc
                     ([ "ok", `Bool semantic_ok
                      ; "via", `String "docker"
                      ; "cwd", Keeper_cwd_response.to_yojson_response cwd_response
                      ; "sandbox_profile", `String "docker"
                      ; "git_creds_enabled", `Bool false
                      ; "network_mode", `String result.network_label
                      ; "effective_sandbox_image", `String result.image
                      ; ( "status"
                        , Keeper_alerting_path.process_status_to_json result.status )
                      ; ( "semantic_status"
                        , `String
                            (Exec_core.string_of_semantic_status semantic_status) )
                      ; "output", `String result.output
                      ]
                      @ gh_exit_class_field
                          ~stages:cmd_stages
                          ~status:result.status
                          ~output:result.output)))))))
;;

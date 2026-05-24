(** Docker/sandbox shell execution infrastructure.

    Extracted from keeper_exec_shell.ml — Docker container lifecycle,
    sandbox profile resolution, and container invocation functions.
    These are pure infrastructure; command dispatch remains in
    keeper_exec_shell.ml. *)

open Keeper_types
open Keeper_exec_shared

include Keeper_sandbox_docker_semantic

let path_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false
;;

let path_is_directory path =
  try Sys.is_directory path with
  | Sys_error _ -> false
;;

let docker_mount_preflight_details
      ~(config : Coord.config)
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

let credential_preflight_failure_json ~keeper_name ~message =
  Yojson.Safe.to_string
    (`Assoc
       [ "ok", `Bool false
       ; "error", `String "keeper_github_credential_blocked"
       ; "failure_class", `String "workflow_rejection"
       ; "retryable", `Bool false
       ; "semantic_status", `String "blocked"
       ; "blocker", `String "keeper_github_credential"
       ; "keeper", `String keeper_name
       ; "detail", `String message
       ; ( "recovery_hint"
         , `String
             "The keeper GitHub credential bundle is unavailable or stale. \
              Re-materialize the selected bundle via dashboard or gh auth login \
              into that bundle before retrying git/gh through the visible Bash \
              or PR tools." )
       ])
;;

let is_credential_preflight_failure message =
  String_util.contains_substring message "Missing_bundle"
  || String_util.contains_substring message "Invalid_token"
;;

let egress_policy_path ~(config : Coord.config) ~(meta : keeper_meta) =
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Filename.concat playground "egress.json"
;;

let check_egress ~(config : Coord.config) ~(meta : keeper_meta) ~cmd =
  let path = egress_policy_path ~config ~meta in
  let policy = Masc_exec.Egress_policy.of_file path in
  match Masc_exec.Egress_policy.check_command policy cmd with
  | Masc_exec.Egress_policy.Allowed -> None
  | Masc_exec.Egress_policy.Blocked _ as blocked ->
    Some (Masc_exec.Egress_policy.blocked_to_json ~expected_policy_path:path blocked)
;;

(* ── Container naming ──────────────────────────────────── *)

let keeper_sandbox_container_name =
  Keeper_sandbox_docker_container_name.keeper_sandbox_container_name
let keeper_private_container_root =
  Keeper_sandbox_docker_container_name.keeper_private_container_root
let docker_private_workspace_cwd =
  Keeper_sandbox_docker_container_name.docker_private_workspace_cwd

let rewrite_docker_command_paths ~(config : Coord.config) ~(meta : keeper_meta) cmd =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> String_util.strip_trailing_slashes
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
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      cmd
  =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> String_util.strip_trailing_slashes
  in
  let normalized_host_root =
    raw_host_root |> Keeper_alerting_path.normalize_path_for_check_stripped
  in
  let container_root =
    keeper_private_container_root meta |> String_util.strip_trailing_slashes
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
let effective_sandbox_profile ~(meta : keeper_meta) ~in_playground =
  match meta.sandbox_profile with
  | Docker ->
    let _ = in_playground in
    Docker, meta.network_mode
  | Local ->
    let _ = in_playground in
    Local, meta.network_mode
;;

(* ── Nested runtime detection ──────────────────────────── *)
include Keeper_sandbox_docker_nested_runtime

(* ── Sandbox runtime preflight ─────────────────────────── *)

let ensure_keeper_sandbox_runtime ~timeout_sec =
  Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec
;;


(* Container worktree gitdir path rewriter extracted to
   [Keeper_sandbox_docker_worktree_gitdir] (godfile decomp). *)
let container_worktree_gitdir_candidates = Keeper_sandbox_docker_worktree_gitdir.candidates
let repair_container_worktree_gitdirs = Keeper_sandbox_docker_worktree_gitdir.repair
let prepare_container_worktree_gitdirs = Keeper_sandbox_docker_worktree_gitdir.prepare

(* ── Docker invocation ─────────────────────────────────── *)

type docker_shell_result =
  { status : Unix.process_status
  ; output : string
  ; image : string
  ; network_label : string
  ; cmd_stages : Keeper_shell_command_semantics.parsed_stage list
  ; cwd : string
  ; semantic_status : Exec_core.semantic_status option
  ; semantic_ok : bool
  }

(** Normalize a Docker invocation result into the common [(status, output)]
    pair used by shell-op handlers.  [Error] maps to a synthetic
    [WEXITED 127] so callers can treat both branches uniformly. *)
let docker_result_pair = function
  | Ok (result : docker_shell_result) -> result.status, result.output
  | Error msg -> Unix.WEXITED 127, msg
;;

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

let docker_run_min_timeout_sec =
  let floor = Timeout_floor.Docker_run in
  let default = Timeout_floor.default_sec floor in
  let raw =
    try float_of_string (Sys.getenv "MASC_KEEPER_DOCKER_RUN_MIN_TIMEOUT_SEC")
    with Not_found | Failure _ -> default
  in
  Timeout_floor.clamp floor raw
;;

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
      (Keeper_sandbox_exec_failure.status_label status)
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

let ensure_docker_shell_image_available ~image ~timeout_sec =
  let argv = Keeper_sandbox_runtime.docker_command_argv () @ [ "image"; "inspect"; image ] in
  let status, output =
    Docker_spawn_throttle.with_slot (fun () ->
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:`System_task_sandbox
        ~raw_source:(String.concat " " argv)
        ~summary:"keeper docker image inspect"
        ~env:(Unix.environment ())
        ~cwd:(Sys.getcwd ())
        ~timeout_sec
        argv)
  in
  if status = Unix.WEXITED 0
  then Ok ()
  else
    Error
      (Printf.sprintf
         "docker_shell_failed: sandbox_image_missing: keeper sandbox image %s is not \
          available locally: %s. Next: Run scripts/build-keeper-sandbox-image.sh to \
          build the default keeper sandbox image, or set \
          MASC_KEEPER_SANDBOX_DOCKER_IMAGE to a locally available image."
         image
         (Exec_policy.truncate_for_log output))
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

let resolve_credential_mounts ~config ~meta ~git_creds_enabled =
  if not git_creds_enabled
  then Ok ([], [])
  else (
    match Keeper_host_config_provider.resolve ~config ~identity:meta.name with
    | Error err -> Error (Keeper_credential_provider.pp_error err)
    | Ok binding ->
      let mounts =
        List.concat_map
          (fun (m : Keeper_credential_provider.ro_mount) ->
             [ "-v"; m.host ^ ":" ^ m.container ^ ":ro" ])
          binding.ro_mounts
      in
      let envs =
        List.concat_map (fun (k, v) -> [ "-e"; k ^ "=" ^ v ]) binding.env
      in
      Ok (mounts, envs))
;;

let docker_run_argv
      ~(config : Coord.config)
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
      ~cred_mounts
      ~cred_envs
      ~identity_mounts
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
  @ Env_config_keeper.KeeperSandbox.read_only_rootfs_args ()
  @ [ "--tmpfs"
    ; Env_config_keeper.KeeperSandbox.tmpfs_mount ()
    ; "--cap-drop=ALL"
    ; "--security-opt"
    ; "no-new-privileges"
    ]
  @ seccomp_args
  @ [ "--pids-limit"
    ; string_of_int (Env_config_keeper.KeeperSandbox.pids_limit ())
    ; "--memory"
    ; Env_config_keeper.KeeperSandbox.memory ()
    ; "-v"
    ; host_root ^ ":" ^ container_root ^ ":rw"
    ; "--workdir"
    ; container_cwd
    ]
  @ Keeper_sandbox_runtime.docker_config_mount_args
      ~base_path:config.base_path
      ~container_root
  @ Keeper_sandbox_runtime.docker_room_state_mount_args
      ~base_path:config.base_path
      ~container_root
  @ network_args
  @ cred_mounts
  @ cred_envs
  @ identity_mounts
  @ [ image; "bash"; "-l"; "-s" ]
;;

let optional_ro_mount ~host ~container =
  if host = ""
  then []
  else if not (Sys.file_exists host)
  then []
  else [ "-v"; host ^ ":" ^ container ^ ":ro" ]
;;

let nested_runtime_blocker ~git_creds_enabled =
  if git_creds_enabled
  then
    "sandbox_profile=docker+git_creds blocks nested container runtimes and host socket \
     references"
  else
    "sandbox_profile=docker blocks nested container runtimes and host socket references"
;;

let sandbox_error_json ~(config : Coord.config) ~(meta : keeper_meta) message =
  Keeper_registry_error_recording.record ~base_path:config.base_path meta.name message;
  error_json message
;;

let sandbox_error ~(config : Coord.config) ~(meta : keeper_meta) ?details message =
  Keeper_registry_error_recording.record ?details ~base_path:config.base_path meta.name message;
  Error message
;;

let parse_cmd_to_ir_opt cmd =
  match Exec_policy.parse_string_to_ir ~mode:Strict cmd with
  | Ok ir -> Some ir
  | Error _ -> None
;;

(** Shared by [run_docker_credentialed_bash], [run_docker_bash], and
    [run_docker_shell_command_with_status_internal]:
    parse cmd → resolve cwd → validate paths.  Returns [Ok (cwd, cmd_stages)]
    when every gate passes.

    [validate_command_paths] toggles the host-side path validation gate
    (default [true]).  Callers that already validated paths (e.g. trusted
    internal dispatch) may pass [false]. *)
let validate_docker_dispatch_context
      ?(validate_command_paths = true)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(cmd : string)
      ()
  =
  let cmd_stages =
    match parse_cmd_to_ir_opt cmd with
    | Some ir -> Keeper_shell_command_semantics.effective_stages_of_ir ir
    | None -> []
  in
  let cwd, sandbox_root_git_blocker =
    Keeper_shell_command_semantics.resolve_sandbox_root_git_cwd_of_stages
      ~config ~meta ~cwd ~cmd cmd_stages
  in
  match sandbox_root_git_blocker with
  | Some message -> Error message
  | None ->
    let path_validation =
      if validate_command_paths
      then (
        let validation_cmd =
          rewrite_docker_command_paths_for_host_validation ~config ~meta cmd
        in
        match parse_cmd_to_ir_opt validation_cmd with
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
    | Error err -> Error (Printf.sprintf "%s [blocked_cmd=%s]" err cmd)
    | Ok () -> Ok (cwd, cmd_stages)
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
  let sandbox_error = sandbox_error ~config ~meta in
  if String.trim image = ""
  then sandbox_error "keeper sandbox docker image is not configured"
  else (
    let cmd = rewrite_docker_command_paths ~config ~meta cmd in
    if command_uses_nested_container_runtime cmd
    then sandbox_error (nested_runtime_blocker ~git_creds_enabled)
    else
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
      | Ok (cwd, cmd_stages) ->
      (match fd_admission_error ~config with
       | Some err -> sandbox_error err
       | None ->
        let host_root =
          Keeper_sandbox.host_root_abs_of_meta ~config meta
          |> Keeper_alerting_path.normalize_path_for_check
          |> String_util.strip_trailing_slashes
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
              Keeper_shell_command_semantics.gh_repo_flag_api_misuse_of_stages
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
                       if
                         git_creds_enabled
                         && String_util.contains_substring_ci cmd "git worktree"
                       then (
                         let prepared =
                           Keeper_sandbox_docker_worktree_gitdir.prepare
                             ~host_root
                             ~container_root
                         in
                         if prepared > 0
                         then
                           Log.Keeper.info
                             "%s: prepared %d docker worktree gitdir path(s) under %s"
                             meta.name
                             prepared
                             host_root;
                         prepared)
                       else 0
                     in
                     let restore_gitdirs () =
                       if prepared_gitdirs > 0
                       then (
                         let restored =
                           Keeper_sandbox_docker_worktree_gitdir.repair
                             ~host_root
                             ~container_root
                         in
                         if restored > 0
                         then
                           Log.Keeper.info
                             "%s: restored %d docker worktree gitdir path(s) under %s"
                             meta.name
                             restored
                             host_root)
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
                         resolve_credential_mounts ~config ~meta ~git_creds_enabled
                       with
                       | Error err -> sandbox_error err
                       | Ok (cred_mounts, cred_envs) ->
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
                                   ~actor:`System_task_sandbox
                                   ~raw_source:(String.concat " " argv)
                                   ~summary:"keeper docker command"
                                   ~env:(Unix.environment ())
                                   ~cwd:(Sys.getcwd ())
                                   ~timeout_sec
                                   ~stdin_content:cmd
                                   argv)
                             in
                             let semantic_status =
                               docker_command_semantic_status ~cmd ~status ~output
                             in
                             let semantic_ok = semantic_ok_of_status semantic_status in
                             if not semantic_ok
                             then
                               Keeper_sandbox_exec_failure.record_docker_failure
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
                             Ok
                               { status
                               ; output
                               ; image
                               ; network_label
                               ; cmd_stages
                               ; cwd
                               ; semantic_status = Some semantic_status
                               ; semantic_ok
                               }
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

(** Preflight checks shared by [run_docker_credentialed_bash] and
    [run_docker_bash]: image configured, nested runtime blocked.
    Returns [Some error_json] on failure, [None] when every gate passes. *)
let docker_bash_preflight ~config ~meta ~cmd ~git_creds_enabled =
  let image = resolve_sandbox_image meta in
  let sandbox_error_json = sandbox_error_json ~config ~meta in
  if String.trim image = ""
  then Some (sandbox_error_json "keeper sandbox docker image is not configured")
  else if command_uses_nested_container_runtime cmd
  then Some (sandbox_error_json (nested_runtime_blocker ~git_creds_enabled))
  else None
;;

let docker_bash_response ~ok ~git_creds_enabled ~image ~network_label ~status ~output
    ~cwd_response ~semantic_status ~cmd_stages
  =
  Yojson.Safe.to_string
    (`Assoc
        ([ "ok", `Bool ok
         ; "via", `String "docker"
         ; "cwd", Keeper_cwd_response.to_yojson_response cwd_response
         ; "sandbox_profile", `String "docker"
         ; "git_creds_enabled", `Bool git_creds_enabled
         ; "network_mode", `String network_label
         ; "effective_sandbox_image", `String image
         ; "status", Keeper_alerting_path.process_status_to_json status
         ]
         @ (match semantic_status with
            | None -> []
            | Some s -> [ "semantic_status", `String (Exec_core.string_of_semantic_status s) ])
         @ [ "output", `String output ]
         @ gh_exit_class_field ~stages:cmd_stages ~status ~output))

(** Convert a [docker_shell_result] into the JSON response string
    shared by container-backed bash paths. *)
let docker_result_to_bash_response ~config ~meta ~git_creds_enabled result =
  let cwd_response =
    Keeper_cwd_response.docker
      ~host_cwd:result.cwd
      ~container_cwd:(docker_private_workspace_cwd ~config ~meta result.cwd)
  in
  docker_bash_response
    ~ok:result.semantic_ok
    ~git_creds_enabled
    ~image:result.image
    ~network_label:result.network_label
    ~status:result.status
    ~output:result.output
    ~cwd_response
    ~semantic_status:result.semantic_status
    ~cmd_stages:result.cmd_stages
;;

(** Shared container-backed bash execution: egress check →
    [run_docker_shell_command_with_status] → response JSON.
    Used by [run_docker_credentialed_bash] and [run_docker_bash]. *)
let run_docker_bash_via_container
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(timeout_sec : float)
      ~(cmd : string)
      ~git_creds_enabled
      ~(network_mode : network_mode)
  =
  match check_egress ~config ~meta ~cmd with
  | Some blocked_json -> blocked_json
  | None ->
    (match
       run_docker_shell_command_with_status
         ~config ~meta ~cwd ~timeout_sec ~cmd ~git_creds_enabled ~network_mode
     with
     | Error message when git_creds_enabled && is_credential_preflight_failure message ->
       credential_preflight_failure_json ~keeper_name:meta.name ~message
     | Error message -> error_json message
     | Ok result ->
       docker_result_to_bash_response ~config ~meta ~git_creds_enabled result)
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
  let _ = turn_sandbox_runtime in
  match docker_bash_preflight ~config ~meta ~cmd ~git_creds_enabled:true with
  | Some err -> err
  | None ->
    run_docker_bash_via_container
      ~config ~meta ~cwd ~timeout_sec ~cmd
      ~git_creds_enabled:true
      ~network_mode:Network_inherit
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
  let image = resolve_sandbox_image meta in
  let sandbox_error_json = sandbox_error_json ~config ~meta in
  match docker_bash_preflight ~config ~meta ~cmd ~git_creds_enabled:false with
  | Some err -> err
  | None -> (
    match turn_sandbox_runtime, network_mode with
    | Some runtime, Network_none ->
      (match validate_docker_dispatch_context ~config ~meta ~cwd ~cmd () with
       | Error message -> sandbox_error_json message
       | Ok (cwd, cmd_stages) ->
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
            let semantic_status =
              docker_command_semantic_status ~cmd ~status:st ~output:out
            in
            let semantic_ok = semantic_ok_of_status semantic_status in
            if not semantic_ok
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
              Keeper_cwd_response.docker
                ~host_cwd:cwd
                ~container_cwd:
                  (Keeper_turn_sandbox_runtime.container_cwd_of_host
                     runtime
                     ~host_cwd:cwd)
            in
            docker_bash_response
              ~ok:semantic_ok
              ~git_creds_enabled:false
              ~image
              ~network_label:(network_mode_to_string network_mode)
              ~status:st
              ~output:out
              ~cwd_response
              ~semantic_status:(Some semantic_status)
              ~cmd_stages
              ))
    | _ ->
      (match turn_sandbox_runtime with
       | Some _ ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_docker_runtime_discarded
           ~labels:[ "keeper", meta.name; "reason", "network_mode_mismatch" ]
           ()
       | None -> ());
      run_docker_bash_via_container
        ~config ~meta ~cwd ~timeout_sec ~cmd
        ~git_creds_enabled:false
        ~network_mode)
;;

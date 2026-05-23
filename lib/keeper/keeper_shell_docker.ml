(** Docker/sandbox shell execution infrastructure.

    Extracted from keeper_exec_shell.ml — Docker container lifecycle,
    sandbox profile resolution, and container invocation functions.
    These are pure infrastructure; command dispatch remains in
    keeper_exec_shell.ml. *)

open Keeper_types
open Keeper_exec_shared

(* Re-export for tests that still call the canonical public surface
   (test_keeper_shell_docker_route). Function body lives in the
   sibling module Keeper_shell_docker_exec_failure. *)
let docker_exec_failure_message =
  Keeper_shell_docker_exec_failure.docker_exec_failure_message

(* Pre-#18044 compat wrappers: parse [cmd] once into effective stages
   and test for gh / git-or-gh prefixes. Live test callers:
   test/test_gh_exit_class_wiring.ml, test_keeper_local_profile_docker_playground.ml,
   test_keeper_exec_status.ml. *)
let cmd_targets_gh cmd =
  Keeper_shell_command_semantics.effective_stages_of_cmd cmd
  |> Keeper_shell_command_semantics.stages_targets_gh

let cmd_targets_git_or_gh cmd =
  Keeper_shell_command_semantics.effective_stages_of_cmd cmd
  |> Keeper_shell_command_semantics.stages_targets_git_or_gh

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

(* ── P12: Network egress policy ───────────────────────── *)

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
  Keeper_shell_docker_container_name.keeper_sandbox_container_name
let keeper_private_container_root =
  Keeper_shell_docker_container_name.keeper_private_container_root
let docker_private_workspace_cwd =
  Keeper_shell_docker_container_name.docker_private_workspace_cwd

let rewrite_docker_command_paths ~(config : Coord.config) ~(meta : keeper_meta) cmd =
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
      ~(config : Coord.config)
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

(* ── Profile resolution ────────────────────────────────── *)

(* Invariant (root-fix family 2/3, 2026-04-28; local-overrotation fix,
   2026-05-18): the declared sandbox profile is the execution contract.
   Docker keepers must never silently fall back to Local, and Local keepers
   must never silently upgrade to Docker.  DockerPlayground is a runtime
   capability switch, not permission to reinterpret sandbox_profile=local. *)
let effective_sandbox_profile ~(meta : keeper_meta) ~in_playground =
  match meta.sandbox_profile with
  | Docker ->
    (* Invariant: meta=Docker → effective=Docker. No silent host fallback. *)
    Docker, meta.network_mode
  | Local ->
    let _ = in_playground in
    Local, meta.network_mode
;;

(* ── Nested runtime detection ──────────────────────────── *)

(* Nested-container runtime detection extracted to
   [Keeper_shell_docker_nested_runtime] (godfile decomp). *)
module Nested_runtime = Keeper_shell_docker_nested_runtime

let nested_container_runtime_tokens = Nested_runtime.nested_container_runtime_tokens
let sandbox_socket_markers = Nested_runtime.sandbox_socket_markers

type shell_guard_token = Nested_runtime.shell_guard_token =
  | Guard_word of string * bool
  | Guard_separator

let shell_guard_tokens = Nested_runtime.shell_guard_tokens
let shell_assignment_like = Nested_runtime.shell_assignment_like
let env_option_takes_arg = Nested_runtime.env_option_takes_arg
let env_option_like = Nested_runtime.env_option_like
let env_split_string_inline_value = Nested_runtime.env_split_string_inline_value
let shell_interpreter_names = Nested_runtime.shell_interpreter_names
let is_shell_interpreter = Nested_runtime.is_shell_interpreter
let word_contains_runtime_token = Nested_runtime.word_contains_runtime_token
let shell_c_payload = Nested_runtime.shell_c_payload
let command_word_mentions_nested_runtime = Nested_runtime.command_word_mentions_nested_runtime

let command_substitution_mentions_nested_runtime =
  Nested_runtime.command_substitution_mentions_nested_runtime
;;

let unquoted_word_mentions_socket_marker = Nested_runtime.unquoted_word_mentions_socket_marker
let command_uses_nested_container_runtime = Nested_runtime.command_uses_nested_container_runtime

(* ── Sandbox runtime preflight ─────────────────────────── *)

let ensure_keeper_sandbox_runtime ~timeout_sec =
  Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec
;;


(* Emit a ("gh_exit_class", "…") JSON field when [cmd_stages] targets gh,
   AND increment the matching Legendary_counters bucket.  Callers
   append the returned list to their `Assoc payload unconditionally —
   it is empty for non-gh commands, so call sites keep their shape. *)
let gh_exit_class_field ~status ~output
    ~(cmd_stages : Keeper_shell_command_semantics.parsed_stage list)
    () : (string * Yojson.Safe.t) list =
  if not (Keeper_shell_command_semantics.stages_targets_gh cmd_stages)
  then []
  else (
    let exit_code =
      match status with
      | Unix.WEXITED n -> n
      | Unix.WSIGNALED n -> 128 + n
      | Unix.WSTOPPED n -> 256 + n
    in
    (* Docker shell captures stdout+stderr combined into [output];
       Gh_exit_class rules match on substrings so passing the combined
       buffer as [stderr] is sound. *)
    let class_ = Gh_exit_class.classify ~exit_code ~stderr:output in
    Legendary_counters.incr_gh_exit_class class_;
    [ "gh_exit_class", `String (Gh_exit_class.to_string class_) ])
;;

let docker_command_semantic_status ~cmd ~status ~output =
  Exec_core.semantic_status_of_process ~cmd ~output status

let docker_command_semantic_success ~cmd ~status ~output =
  match docker_command_semantic_status ~cmd ~status ~output with
  | Exec_core.Ok | Exec_core.No_match -> true
  | Exec_core.Partial | Exec_core.Blocked | Exec_core.Timeout | Exec_core.Runtime_error ->
    false

let optional_ro_mount ~host ~container =
  if host = ""
  then []
  else if not (Sys.file_exists host)
  then []
  else [ "-v"; host ^ ":" ^ container ^ ":ro" ]
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
let docker_run_min_timeout_sec =
  let floor = Timeout_floor.Docker_run in
  let default = Timeout_floor.default_sec floor in
  let raw =
    try float_of_string (Sys.getenv "MASC_KEEPER_DOCKER_RUN_MIN_TIMEOUT_SEC")
    with Not_found | Failure _ -> default
  in
  Timeout_floor.clamp floor raw

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
      (Keeper_shell_docker_exec_failure.docker_exec_status_label status)
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
  let image =
    match meta.sandbox_image with
    | Some img when String.trim img <> "" -> img
    | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
  in
  let sandbox_error ?details message =
    Keeper_registry_error_recording.record ?details ~base_path:config.base_path meta.name message;
    Error message
  in
  if String.trim image = ""
  then sandbox_error "keeper sandbox docker image is not configured"
  else (
    let cmd = rewrite_docker_command_paths ~config ~meta cmd in
    if command_uses_nested_container_runtime cmd
    then
      sandbox_error
        (if git_creds_enabled
         then
           "sandbox_profile=docker+git_creds blocks nested container runtimes and host \
            socket references"
         else
           "sandbox_profile=docker blocks nested container runtimes and host socket \
            references")
    else
      let cmd_stages =
        Keeper_shell_command_semantics.effective_stages_of_cmd cmd
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
          (match Exec_policy_mutation_classifier.parsed_of_string validation_cmd with
           | Masc_exec.Parsed.Parsed validation_ir ->
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
           | Masc_exec.Parsed.Parse_error _
           | Masc_exec.Parsed.Parse_aborted _
           | Masc_exec.Parsed.Too_complex _ -> Ok ())
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
              (* Pre-flight: verify the bind source and host cwd before spawning a
                 container. Missing bind sources otherwise fail inside Docker
                 Desktop as opaque OCI mount errors and can degrade the daemon. *)
              if not (path_exists host_root)
              then
                let details =
                  docker_mount_preflight_details
                    ~config
                    ~meta
                    ~image
                    ~container_kind:"oneshot"
                    ~network_label
                    ~mount_path:host_root
                    ~reason:"mount_source_not_found"
                in
                sandbox_error
                  ~details
                  (Printf.sprintf
                     "docker_shell_failed: mount_source_not_found: mount_path=%S \
                      base_path_hash=%S keeper=%S image=%S container_kind=%S \
                      network=%S (host bind mount source does not exist; repair \
                      the sandbox playground before docker run)"
                     host_root
                     (Keeper_sandbox_runtime.base_path_hash config.base_path)
                     meta.name
                     image
                     "oneshot"
                     network_label)
              else if not (path_is_directory host_root)
              then
                let details =
                  docker_mount_preflight_details
                    ~config
                    ~meta
                    ~image
                    ~container_kind:"oneshot"
                    ~network_label
                    ~mount_path:host_root
                    ~reason:"mount_source_not_directory"
                in
                sandbox_error
                  ~details
                  (Printf.sprintf
                     "docker_shell_failed: mount_source_not_directory: mount_path=%S \
                      base_path_hash=%S keeper=%S image=%S container_kind=%S \
                      network=%S (host bind mount source must be a directory)"
                     host_root
                     (Keeper_sandbox_runtime.base_path_hash config.base_path)
                     meta.name
                     image
                     "oneshot"
                     network_label)
              else if not (path_exists cwd)
              then
                sandbox_error
                  (Printf.sprintf
                     "docker_shell_failed: cwd_not_found: %s (host working directory \
                      does not exist; verify the relative path under your playground \
                     before calling keeper_shell)"
                     cwd)
              else if not (path_is_directory cwd)
              then
                sandbox_error
                  (Printf.sprintf
                     "docker_shell_failed: cwd_not_directory: %s (working directory must \
                      be a directory, not a file)"
                     cwd)
              else (
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
                       if git_creds_enabled
                          && Keeper_shell_command_semantics.stages_targets_git_or_gh cmd_stages
                       then prepare_container_worktree_gitdirs ~host_root ~container_root
                       else 0
                     in
                     let restore_gitdirs () =
                       if git_creds_enabled
                       then (
                         let restored =
                           repair_container_worktree_gitdirs ~host_root ~container_root
                         in
                         if restored > 0
                         then
                           Log.Keeper.info
                             "%s: restored %d docker worktree gitdir path(s) under %s"
                             meta.name
                             restored
                             host_root)
                     in
                     if prepared_gitdirs > 0
                     then
                       Log.Keeper.info
                         "%s: prepared %d docker worktree gitdir path(s) under %s"
                         meta.name
                         prepared_gitdirs
                         host_root;
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
                       let cred_result =
                         if not git_creds_enabled
                         then Ok ([], [])
                         else (
                           (* Credential composition is centralised in
             [Keeper_host_config_provider.resolve].  It selects either the
             keeper's explicit GitHub identity bundle or the MASC-owned
             root bundle.  Ambient operator GH_TOKEN/GITHUB_TOKEN,
             ~/.config/gh, ~/.ssh, and keychain probes are not part of
             keeper execution. *)
                           match
                             Keeper_host_config_provider.resolve
                               ~config
                               ~identity:meta.name
                           with
                           | Error err -> Error (Keeper_credential_provider.pp_error err)
                           | Ok binding ->
                             let mounts =
                               List.concat_map
                                 (fun (m : Keeper_credential_provider.ro_mount) ->
                                    [ "-v"; m.host ^ ":" ^ m.container ^ ":ro" ])
                                 binding.ro_mounts
                             in
                             let envs =
                               List.concat_map
                                 (fun (k, v) -> [ "-e"; k ^ "=" ^ v ])
                                 binding.env
                             in
                             Ok (mounts, envs))
                       in
                       (match cred_result with
                        | Error err -> sandbox_error err
                        | Ok (cred_mounts, cred_envs) ->
                          let argv =
                            Keeper_sandbox_runtime.docker_command_argv ()
                            @ [ "run"; "--rm"; "--name"; container_name ]
                            @ Keeper_sandbox_runtime.docker_label_args
                                ~base_path:config.base_path
                                ~keeper_name:meta.name
                                ~container_kind:"oneshot"
                                ~network_label
                                ~ttl_sec:(docker_oneshot_ttl_sec ~timeout_sec)
                                ()
                            @ [ "-i"; "--user"; Printf.sprintf "%d:%d" uid gid ]
                            @ Keeper_sandbox_runtime.docker_sandbox_env_args
                                ~base_path:config.base_path
                                ~container_root
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
                               Keeper_shell_docker_exec_failure.record_docker_exec_failure
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
      "sandbox_profile=docker+git_creds blocks nested container runtimes and host socket \
       references"
  else (
    (* P12: check egress policy for git commands with network access *)
    match check_egress ~config ~meta ~cmd with
    | Some blocked_json -> blocked_json
    | None ->
      let cmd_stages =
        Keeper_shell_command_semantics.effective_stages_of_cmd cmd
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
           match Exec_policy_mutation_classifier.parsed_of_string validation_cmd with
           | Masc_exec.Parsed.Parsed validation_ir ->
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
           | Masc_exec.Parsed.Parse_error _
           | Masc_exec.Parsed.Parse_aborted _
           | Masc_exec.Parsed.Too_complex _ -> Ok ()
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
                         ~status:result.status
                         ~output:result.output
                        ~cmd_stages
                        ()))))))
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
      Keeper_shell_command_semantics.effective_stages_of_cmd cmd
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
        match Exec_policy_mutation_classifier.parsed_of_string validation_cmd with
        | Masc_exec.Parsed.Parsed validation_ir ->
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
        | Masc_exec.Parsed.Parse_error _
        | Masc_exec.Parsed.Parse_aborted _
        | Masc_exec.Parsed.Too_complex _ -> Ok ()
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
              Keeper_shell_docker_exec_failure.record_docker_exec_failure
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
                   @ gh_exit_class_field ~status:st ~output:out ~cmd_stages ())))
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
                          ~status:result.status
                          ~output:result.output
                          ~cmd_stages
                          ())))))))
;;

(** Docker/sandbox shell execution infrastructure.

    Extracted from keeper_exec_shell.ml — Docker container lifecycle,
    sandbox profile resolution, and container invocation functions.
    These are pure infrastructure; command dispatch remains in
    keeper_exec_shell.ml. *)

open Keeper_types
open Keeper_exec_shared

(* ── Sandbox GH_TOKEN warn dedup ───────────────────────────

   When [git_creds_enabled = true] but [Env_config_keeper.KeeperSandbox.gh_token]
   returns the empty string, the keeper subprocess inside docker has *no*
   GitHub credential — every [gh pr create]/[git push] inside the sandbox
   returns 401, which operators only see as an unstructured CLI error from
   the keeper turn output.  The 3-tier resolution chain
   ([env_config_keeper.ml:700-748]: MASC_KEEPER_SANDBOX_GH_TOKEN env →
   host GH_TOKEN env → cached `gh auth token` keychain probe) silently
   collapses to "" and the [-e GH_TOKEN=...] argv slot is omitted.

   Symmetric to #10973's expire_stale-never-called dead-end: function and
   policy exist, single missing log line leaves the operator blind.  The
   per-keeper dedup keeps log noise bounded — the resolution chain is
   process-global cached, so the warn only needs to fire once per keeper
   per server lifetime. *)
let gh_token_warn_emitted : (string, unit) Hashtbl.t = Hashtbl.create 16
let gh_token_warn_mu = Eio.Mutex.create ()

let warn_sandbox_gh_token_missing keeper_name =
  let should_emit =
    Eio.Mutex.use_rw ~protect:true gh_token_warn_mu (fun () ->
      if Hashtbl.mem gh_token_warn_emitted keeper_name then false
      else begin
        Hashtbl.add gh_token_warn_emitted keeper_name ();
        true
      end)
  in
  if should_emit then begin
    Prometheus.inc_counter
      "masc_keeper_sandbox_gh_token_missing_total"
      ~labels:[ ("keeper", keeper_name) ]
      ();
    Log.Keeper.warn
      "%s: sandbox GH_TOKEN unavailable — gh/git HTTPS calls inside the \
       container will return 401.  Resolution chain (env_config_keeper.ml \
       KeeperSandbox.gh_token): 1) MASC_KEEPER_SANDBOX_GH_TOKEN env, \
       2) host GH_TOKEN env, 3) cached `gh auth token` keychain probe.  \
       On macOS the keychain probe is permanently cached at server start; \
       run `gh auth status` to verify credentials, then restart masc-mcp \
       so the probe re-runs."
      keeper_name
  end

(* ── P12: Network egress policy ───────────────────────── *)

let egress_policy_path ~(config : Coord.config) ~(meta : keeper_meta) =
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Filename.concat playground "egress.json"

let check_egress ~(config : Coord.config) ~(meta : keeper_meta) ~cmd =
  let path = egress_policy_path ~config ~meta in
  let policy = Masc_exec.Egress_policy.of_file path in
  match Masc_exec.Egress_policy.check_command policy cmd with
  | Masc_exec.Egress_policy.Allowed -> None
  | Masc_exec.Egress_policy.Blocked _ as blocked ->
      Some
        (Masc_exec.Egress_policy.blocked_to_json
           ~expected_policy_path:path blocked)

(* ── Container naming ──────────────────────────────────── *)

let keeper_sandbox_container_name (meta : keeper_meta) =
  Printf.sprintf "masc-keeper-%s-%d-%d"
    (Coord_utils.safe_filename meta.name)
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))

let keeper_private_container_root (meta : keeper_meta) =
  Keeper_sandbox.container_root meta.name

let docker_private_workspace_cwd ~(config : Coord.config) ~(meta : keeper_meta)
    host_cwd =
  let normalize_path_for_containment path =
    Keeper_alerting_path.normalize_path_for_check path
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> normalize_path_for_containment
  in
  let container_root = keeper_private_container_root meta in
  let host_cwd = normalize_path_for_containment host_cwd in
  if host_cwd = host_root then
    container_root
  else if String.starts_with ~prefix:(host_root ^ "/") host_cwd then
    let suffix =
      String.sub host_cwd (String.length host_root + 1)
        (String.length host_cwd - String.length host_root - 1)
    in
    Filename.concat container_root suffix
  else
    container_root

(* ── Profile resolution ────────────────────────────────── *)

let effective_sandbox_profile ~(meta : keeper_meta) ~in_playground =
  if Env_config_keeper.KeeperSandbox.hard_mode () then
    (meta.sandbox_profile, meta.network_mode)
  else if meta.sandbox_profile = Local
     && Env_config_keeper.DockerPlayground.enabled
     && in_playground
  then
    (Docker, Network_inherit)
  else
    (meta.sandbox_profile, meta.network_mode)

(* ── Nested runtime detection ──────────────────────────── *)

let nested_container_runtime_tokens =
  [ "docker"; "podman"; "nerdctl"; "buildah" ]

let sandbox_socket_markers =
  [
    "/var/run/docker.sock";
    "/run/docker.sock";
    "/run/podman/podman.sock";
    "podman.sock";
    "containerd.sock";
    "buildkitd.sock";
  ]

let command_uses_nested_container_runtime cmd =
  let lowered_words = lowercase_shell_words cmd in
  let lowered_cmd = String.lowercase_ascii cmd in
  List.exists (fun token -> List.mem token nested_container_runtime_tokens)
    lowered_words
  || List.exists (String_util.contains_substring lowered_cmd) sandbox_socket_markers

(* ── Sandbox runtime preflight ─────────────────────────── *)

let ensure_keeper_sandbox_runtime ~timeout_sec =
  Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec

let cmd_targets_git_or_gh cmd =
  let trimmed = String.trim cmd in
  let first_word =
    match String.index_opt trimmed ' ' with
    | Some i -> String.sub trimmed 0 i
    | None -> trimmed
  in
  match first_word with
  | "git" | "gh" -> true
  | _ ->
    (* Also detect git/gh after cd or other prefix commands.
       LLMs frequently generate "cd <path> && gh pr view ..." which
       has "cd" as the first word but the meaningful operation is
       git/gh. *)
    let tokens = String.split_on_char ' ' trimmed in
    List.exists (fun tok -> tok = "git" || tok = "gh") tokens

let cmd_targets_gh cmd =
  let trimmed = String.trim cmd in
  let first_word =
    match String.index_opt trimmed ' ' with
    | Some i -> String.sub trimmed 0 i
    | None -> trimmed
  in
  if first_word = "gh" then true
  else
    (* Same "prefixed by cd ..." allowance as cmd_targets_git_or_gh,
       but strict to gh for classification purposes. *)
    let tokens = String.split_on_char ' ' trimmed in
    List.exists (fun tok -> tok = "gh") tokens

(* #10855: keeper LLM (issue_king, masc-improver) hallucinated gh syntax
   `gh --repo X api Y` (108 events / 24h, 2026-04-25→04-26). gh CLI
   semantics: `--repo` is a subcommand flag (gh issue/pr/release/...),
   not a global option, and `gh api` rejects it with "unknown flag: --repo".
   Detect the misuse pre-exec so we can emit a self-correcting error
   instead of letting the docker exec waste a turn surfacing gh's raw
   error.  Same self-correcting-message pattern as #10869's multi-repo
   sandbox blocker. *)
let detect_gh_repo_flag_with_api_misuse cmd =
  let strip_quotes s =
    let len = String.length s in
    if len >= 2
       && ((s.[0] = '\'' && s.[len-1] = '\'')
           || (s.[0] = '"' && s.[len-1] = '"'))
    then String.sub s 1 (len - 2)
    else s
  in
  let toks =
    String.split_on_char ' ' (String.trim cmd)
    |> List.filter (fun s -> s <> "")
    |> List.map strip_quotes
  in
  if not (List.mem "gh" toks) then None
  else
    let rec scan = function
      | "--repo" :: repo_arg :: "api" :: endpoint :: _ ->
          Some (repo_arg, endpoint)
      | _ :: rest -> scan rest
      | [] -> None
    in
    scan toks

(* Emit a ("gh_exit_class", "…") JSON field when [cmd] targets gh,
   AND increment the matching Legendary_counters bucket.  Callers
   append the returned list to their `Assoc payload unconditionally —
   it is empty for non-gh commands, so call sites keep their shape. *)
let gh_exit_class_field ~cmd ~status ~output : (string * Yojson.Safe.t) list =
  if not (cmd_targets_gh cmd) then []
  else
    let exit_code = match status with
      | Unix.WEXITED n -> n
      | Unix.WSIGNALED n -> 128 + n
      | Unix.WSTOPPED n -> 256 + n
    in
    (* Docker shell captures stdout+stderr combined into [output];
       Gh_exit_class rules match on substrings so passing the combined
       buffer as [stderr] is sound. *)
    let class_ = Gh_exit_class.classify ~exit_code ~stderr:output in
    Legendary_counters.incr_gh_exit_class class_;
    [ ("gh_exit_class", `String (Gh_exit_class.to_string class_)) ]

let optional_ro_mount ~host ~container =
  if host = "" then []
  else if not (Sys.file_exists host) then []
  else [ "-v"; host ^ ":" ^ container ^ ":ro" ]

(* ── Docker invocation ─────────────────────────────────── *)

type docker_shell_result =
  {
    status : Unix.process_status;
    output : string;
    image : string;
    network_label : string;
  }

(* docker run --rm includes image layer pull + container creation cold start.
   A 1s floor is insufficient even for trivial commands. This minimum applies
   only to the run path, not to docker exec against a warm container. *)
let docker_run_min_timeout_sec = 5.0

let run_docker_shell_command_with_status
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(cwd : string)
    ~(timeout_sec : float)
    ~(cmd : string)
    ~(git_creds_enabled : bool)
    ~(network_mode : network_mode)
  =
  let timeout_sec = max timeout_sec docker_run_min_timeout_sec in
  let image = Env_config_keeper.KeeperSandbox.docker_image () in
  let network_mode =
    if Env_config_keeper.KeeperSandbox.hard_mode () then
      Network_none
    else
      network_mode
  in
  let sandbox_error message =
    Keeper_registry.record_error ~base_path:config.base_path meta.name message;
    Error message
  in
  if String.trim image = "" then
    sandbox_error "keeper sandbox docker image is not configured"
  else if git_creds_enabled && Env_config_keeper.KeeperSandbox.hard_mode () then
    sandbox_error
      "sandbox hard mode forbids Docker git credential dispatch; use keeper_shell op=git_clone or op=gh so git/gh egress is brokered outside the container"
  else if command_uses_nested_container_runtime cmd then
    sandbox_error
      (if git_creds_enabled then
         "sandbox_profile=docker+git_creds blocks nested container runtimes and host socket references"
       else
         "sandbox_profile=docker blocks nested container runtimes and host socket references")
  else
    let _cleanup =
      Keeper_sandbox_runtime.maybe_cleanup_stale_containers
        ~base_path:config.base_path
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Sandbox ())
        ()
    in
    match ensure_keeper_sandbox_runtime ~timeout_sec with
    | Error err -> sandbox_error err
    | Ok seccomp_args ->
      let host_root =
        keeper_playground_root ~config ~meta
        |> Keeper_alerting_path.normalize_path_for_check
        |> Keeper_alerting_path.strip_trailing_slashes
      in
      (* #10424: keeper LLM이 sandbox root에서 cd 없이 git/gh 호출 시
         "fatal: not a git repository" 발생. mount point는 git repo 아니고
         repos/<repo>/ 안에만 git checkout 존재. filesystem ground truth
         (repos/ enumeration)로 결정론적 분기:
         - single-repo → 자동 chdir (silent)
         - multi-repo → explicit error로 LLM이 정확한 경로 학습
         - 0 repo → preserve (system misconfig은 별도 fail) *)
      let cwd_normalized =
        Keeper_alerting_path.normalize_path_for_check cwd
        |> Keeper_alerting_path.strip_trailing_slashes
      in
      let repos_in_playground () =
        let repos_dir = Filename.concat host_root "repos" in
        if not (Sys.file_exists repos_dir && Sys.is_directory repos_dir) then []
        else
          try
            Sys.readdir repos_dir
            |> Array.to_list
            |> List.filter (fun name ->
              let p = Filename.concat repos_dir name in
              try Sys.is_directory p with Sys_error _ -> false)
            |> List.sort compare
          with Sys_error _ -> []
      in
      let cwd, multi_repo_blocker =
        if cwd_normalized = host_root && cmd_targets_git_or_gh cmd then
          match repos_in_playground () with
          | [single_repo] ->
            (Filename.concat (Filename.concat host_root "repos") single_repo, None)
          | [] -> (cwd, None)
          | example_repo :: _ as many ->
            (* #10680: keeper-executor-agent saw 17 events / 5min in a single
               session (mcp_VHsjtow_92C_2a0o, 2026-04-26 08:00→08:06) where
               the LLM read this descriptive error and still re-issued the
               same bare git/gh in the next turn.  Make the message
               self-correcting: include the original cmd and the exact
               next-call shape so the LLM can copy-paste rather than
               re-derive the cwd convention from prose. *)
            let cmd_preview =
              let s = String.trim cmd in
              if String.length s > 120 then String.sub s 0 117 ^ "..." else s
            in
            ( cwd
            , Some
                (Printf.sprintf
                   "sandbox root에서 git/gh 직접 호출 불가 \
                    (mount point %s는 git repo 아님). \
                    필수: 다음 호출에서 cwd를 명시. 예: \
                    keeper_bash { cmd: \"cd repos/%s && %s\" } \
                    (가능한 repo: %s). \
                    같은 cmd를 다음 turn에서 cwd 변경 없이 다시 호출하지 마세요."
                   host_root
                   example_repo
                   cmd_preview
                   (String.concat ", " many)) )
        else (cwd, None)
      in
      match multi_repo_blocker with
      | Some msg -> sandbox_error msg
      | None ->
      (* #10855: surface gh syntax misuse before docker exec so the LLM
         sees a corrected-form hint in the same turn rather than gh's raw
         "unknown flag: --repo" error after the round-trip. *)
      match detect_gh_repo_flag_with_api_misuse cmd with
      | Some (repo_arg, endpoint) ->
        sandbox_error
          (Printf.sprintf
             "잘못된 gh syntax: 'gh --repo %s api %s ...' \
              — '--repo' 는 subcommand flag (gh issue/pr/release/run) 전용이고 \
              'gh api' 에는 적용 안 됨. \
              올바른 형태: 'gh api repos/%s/%s' (endpoint 안에 org/repo 포함). \
              다음 turn 에서 cmd 를 수정하세요."
             repo_arg endpoint repo_arg endpoint)
      | None ->
      let container_name = keeper_sandbox_container_name meta in
      let container_root = keeper_private_container_root meta in
      let container_cwd = docker_private_workspace_cwd ~config ~meta cwd in
      let uid = Unix.getuid () in
      let gid = Unix.getgid () in
      let network_args, network_label =
        if git_creds_enabled then
          ([ "--network"; "bridge" ], "bridge")
        else
          Keeper_sandbox_runtime.docker_network_args network_mode
      in
      let cred_root = Host_config_provider.cred_root in
      let cred_result =
        if not git_creds_enabled then
          Ok ([], [])
        else
          (* RFC-0008 PR-1: composition centralised in
             [Host_config_provider.resolve].  Pre-extraction this
             site inlined ~60 lines reading from
             [Keeper_gh_env.keeper_binding], [Env_config_sandbox.Auth_paths],
             [Keeper_identity], and [Env_git_noninteractive].  The
             trait keeps that surface identical (no new env keys, no
             new mounts) and makes the lifecycle explicit so PR-3
             can swap to [In_container_login_provider] without
             rewiring this caller.  See RFC-0008 §3 / §4. *)
          match
            Host_config_provider.resolve ~config ~identity:meta.name
          with
          | Error err ->
              Error (Credential_provider.pp_error err)
          | Ok binding ->
              let mounts =
                List.concat_map
                  (fun (m : Credential_provider.ro_mount) ->
                    [ "-v"; m.host ^ ":" ^ m.container ^ ":ro" ])
                  binding.ro_mounts
              in
              let envs =
                List.concat_map
                  (fun (k, v) -> [ "-e"; k ^ "=" ^ v ])
                  binding.env
              in
              Ok (mounts, envs)
      in
      match cred_result with
      | Error err -> sandbox_error err
      | Ok (cred_mounts, cred_envs) ->
      let ssh_auth_sock = Sys.getenv_opt "SSH_AUTH_SOCK" in
      let ssh_auth_mount, ssh_auth_env =
        let empty = ([], []) in
        if not git_creds_enabled then empty
        else
          match ssh_auth_sock with
          | None -> empty
          | Some path when Sys.file_exists path ->
              let container_path =
                Filename.concat cred_root "ssh-agent.sock"
              in
              ( [ "-v"; path ^ ":" ^ container_path ],
                [ "-e"; "SSH_AUTH_SOCK=" ^ container_path ] )
          | Some _ -> empty
      in
      let token_env =
        let gh_token =
          if git_creds_enabled then
            Env_config_keeper.KeeperSandbox.gh_token ()
          else
            ""
        in
        if git_creds_enabled && gh_token = "" then
          warn_sandbox_gh_token_missing meta.name;
        if (not git_creds_enabled) || gh_token = "" then
          []
        else
          [ "-e"; "GH_TOKEN=" ^ gh_token ]
      in
      let argv =
        Keeper_sandbox_runtime.docker_command_argv ()
        @ [
            "run";
            "--rm";
            "--name";
            container_name;
          ]
        @ Keeper_sandbox_runtime.docker_label_args
            ~base_path:config.base_path
            ~keeper_name:meta.name
            ~container_kind:"oneshot"
            ~network_label ()
        @ [
          "-i";
          "--user";
          Printf.sprintf "%d:%d" uid gid;
        ]
        @ Keeper_sandbox_runtime.docker_nofile_args ()
        @ Env_config_keeper.KeeperSandbox.read_only_rootfs_args ()
        @ [
          "--tmpfs";
          Env_config_keeper.KeeperSandbox.tmpfs_mount ();
          "--cap-drop=ALL";
          "--security-opt";
          "no-new-privileges";
        ]
        @ seccomp_args
        @ [
          "--pids-limit";
          string_of_int (Env_config_keeper.KeeperSandbox.pids_limit ());
          "--memory";
          Env_config_keeper.KeeperSandbox.memory ();
          "-v";
          host_root ^ ":" ^ container_root ^ ":rw";
          "--workdir";
          container_cwd;
        ]
        @ network_args
        @ cred_mounts
        @ cred_envs
        @ ssh_auth_mount
        @ ssh_auth_env
        @ token_env
        @ [ image; "bash"; "-lc"; cmd ]
      in
      (try
         let status, output =
           Process_eio.run_argv_with_status
             ~env:(Unix.environment ())
             ~cwd:(Sys.getcwd ()) ~timeout_sec argv
         in
         if status <> Unix.WEXITED 0 then
           Keeper_registry.record_error ~base_path:config.base_path meta.name
             (Printf.sprintf "sandbox docker exec failed (%s): %s"
                image
                (Worker_dev_tools.truncate_for_log output))
         else
           Keeper_registry.clear_error ~base_path:config.base_path meta.name;
         Ok { status; output; image; network_label }
       with
       | Failure err -> sandbox_error err)

let run_docker_with_git_bash
    ~(turn_sandbox_runtime : Keeper_turn_sandbox_runtime.t option)
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(cwd : string)
    ~(timeout_sec : float)
    ~(cmd : string) () =
  let image = Env_config_keeper.KeeperSandbox.docker_image () in
  let sandbox_error_json message =
    Keeper_registry.record_error ~base_path:config.base_path meta.name message;
    error_json message
  in
  if String.trim image = "" then
    sandbox_error_json "keeper sandbox docker image is not configured"
  else if Env_config_keeper.KeeperSandbox.hard_mode () then
    sandbox_error_json
      "sandbox hard mode forbids Docker git credential dispatch; use keeper_shell op=git_clone or op=gh so git/gh egress is brokered outside the container"
  else if command_uses_nested_container_runtime cmd then
    sandbox_error_json
      "sandbox_profile=docker+git_creds blocks nested container runtimes and host socket references"
  else
    (* P12: check egress policy for git commands with network access *)
    (match check_egress ~config ~meta ~cmd with
     | Some blocked_json -> blocked_json
     | None ->
    match turn_sandbox_runtime with
    | Some runtime ->
      (match
         Keeper_turn_sandbox_runtime.run_bash_with_status runtime
           ~cwd ~cmd ~timeout_sec ()
       with
       | Error message -> sandbox_error_json message
       | Ok (st, out) ->
         if st <> Unix.WEXITED 0 then
           Keeper_registry.record_error ~base_path:config.base_path meta.name
             (Printf.sprintf "sandbox docker exec failed (%s): %s"
                image
                (Worker_dev_tools.truncate_for_log out))
         else
           Keeper_registry.clear_error ~base_path:config.base_path meta.name;
         Yojson.Safe.to_string
           (`Assoc
              ([
                ("ok", `Bool (st = Unix.WEXITED 0));
                ("via", `String "docker");
                ("cwd", `String cwd);
                ("sandbox_profile", `String "docker");
                ("git_creds_enabled", `Bool true);
                ("network_mode", `String (network_mode_to_string Network_inherit));
                ("effective_sandbox_image", `String image);
                ("status", Keeper_alerting_path.process_status_to_json st);
                ("output", `String out);
              ] @ gh_exit_class_field ~cmd ~status:st ~output:out)))
    | None ->
      match
        run_docker_shell_command_with_status ~config ~meta ~cwd ~timeout_sec
          ~cmd ~git_creds_enabled:true ~network_mode:Network_inherit
      with
      | Error message -> error_json message
      | Ok result ->
        Yojson.Safe.to_string
          (`Assoc
             ([
               ("ok", `Bool (result.status = Unix.WEXITED 0));
               ("via", `String "docker");
               ("cwd", `String cwd);
               ("sandbox_profile", `String "docker");
               ("git_creds_enabled", `Bool true);
               ("network_mode", `String result.network_label);
               ("effective_sandbox_image", `String result.image);
               ( "status",
                 Keeper_alerting_path.process_status_to_json result.status );
               ("output", `String result.output);
             ] @ gh_exit_class_field ~cmd ~status:result.status ~output:result.output)))

let run_docker_hardened_bash
    ~(turn_sandbox_runtime : Keeper_turn_sandbox_runtime.t option)
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(cwd : string)
    ~(timeout_sec : float)
    ~(cmd : string)
    ~(network_mode : network_mode) =
  let image = Env_config_keeper.KeeperSandbox.docker_image () in
  let sandbox_error_json message =
    Keeper_registry.record_error ~base_path:config.base_path meta.name message;
    error_json message
  in
  if String.trim image = "" then
    sandbox_error_json "keeper sandbox docker image is not configured"
  else if command_uses_nested_container_runtime cmd then
    sandbox_error_json
      "sandbox_profile=docker blocks nested container runtimes and host socket references"
  else
    match turn_sandbox_runtime, network_mode with
    | Some runtime, Network_none ->
      (match
         Keeper_turn_sandbox_runtime.run_bash_with_status runtime
           ~cwd ~cmd ~timeout_sec ()
       with
       | Error message -> sandbox_error_json message
       | Ok (st, out) ->
         if st <> Unix.WEXITED 0 then
           Keeper_registry.record_error ~base_path:config.base_path meta.name
             (Printf.sprintf "sandbox docker exec failed (%s): %s"
                image
                (Worker_dev_tools.truncate_for_log out))
         else
           Keeper_registry.clear_error ~base_path:config.base_path meta.name;
         Yojson.Safe.to_string
           (`Assoc
              ([
                ("ok", `Bool (st = Unix.WEXITED 0));
                ("via", `String "docker");
                ("cwd", `String cwd);
                ("sandbox_profile", `String "docker");
                ("git_creds_enabled", `Bool false);
                ("network_mode", `String (network_mode_to_string network_mode));
                ("effective_sandbox_image", `String image);
                ("status", Keeper_alerting_path.process_status_to_json st);
                ("output", `String out);
              ] @ gh_exit_class_field ~cmd ~status:st ~output:out)))
    | _ ->
      (* P12: check egress policy before running networked container *)
      (match check_egress ~config ~meta ~cmd with
       | Some blocked_json -> blocked_json
       | None ->
       match
        run_docker_shell_command_with_status ~config ~meta ~cwd ~timeout_sec
          ~cmd ~git_creds_enabled:false ~network_mode
      with
      | Error message -> error_json message
      | Ok result ->
        Yojson.Safe.to_string
          (`Assoc
             ([
               ("ok", `Bool (result.status = Unix.WEXITED 0));
               ("via", `String "docker");
               ("cwd", `String cwd);
               ("sandbox_profile", `String "docker");
               ("git_creds_enabled", `Bool false);
               ("network_mode", `String result.network_label);
               ("effective_sandbox_image", `String result.image);
               ( "status",
                 Keeper_alerting_path.process_status_to_json result.status );
               ("output", `String result.output);
             ] @ gh_exit_class_field ~cmd ~status:result.status ~output:result.output)))

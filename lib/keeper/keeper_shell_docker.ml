(** Docker/sandbox shell execution infrastructure.

    Extracted from keeper_exec_shell.ml — Docker container lifecycle,
    sandbox profile resolution, and container invocation functions.
    These are pure infrastructure; command dispatch remains in
    keeper_exec_shell.ml. *)

open Keeper_types
open Keeper_exec_shared

(* docker exec 실패 시 진단성 보강용 helper. 이전 message format
   `failed (image): <output>` 에서 output 이 empty 면 진단 불가
   (cycle22 fleet log: 30분간 5건 발생, detail 모두 empty).
   exit/signal status + output empty placeholder 로 root cause 식별
   가능하게 한다. *)
let docker_exec_status_label = function
  | Unix.WEXITED n -> Printf.sprintf "exit=%d" n
  | Unix.WSIGNALED n -> Printf.sprintf "signal=%d" n
  | Unix.WSTOPPED n -> Printf.sprintf "stopped=%d" n

let docker_exec_failure_message ~image ~status ~output =
  let truncated = Worker_dev_tools.truncate_for_log output in
  let output_label =
    if String.trim truncated = "" then "<no output>" else truncated
  in
  let missing_cwd_hint =
    if String_util.contains_substring output "cd:"
       && String_util.contains_substring output "No such file or directory"
    then
      " hint=cwd_not_directory: create or repair the sandbox repo/worktree first (keeper_shell op=git_clone, then git_worktree/masc_worktree_create for repos/<repo>/.worktrees/<task>)."
    else ""
  in
  Printf.sprintf "sandbox docker exec failed (%s, %s): %s%s"
    image (docker_exec_status_label status) output_label missing_cwd_hint

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

let rewrite_docker_command_paths ~(config : Coord.config) ~(meta : keeper_meta)
    cmd =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let normalized_host_root =
    raw_host_root
    |> Keeper_alerting_path.normalize_path_for_check
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let container_root = keeper_private_container_root meta in
  let rewritten =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:raw_host_root ~container_root cmd
  in
  if String.equal raw_host_root normalized_host_root then rewritten
  else
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:normalized_host_root ~container_root rewritten

(* ── Profile resolution ────────────────────────────────── *)

(* Invariant (root-fix family 2/3, 2026-04-28):
   When [meta.sandbox_profile = Docker], the effective profile is ALWAYS
   Docker, regardless of [in_playground]. The historical behavior of
   silently dropping back to Local when the cwd was outside the playground
   was the proximate cause of the host-fallback bypass reported in the
   2026-04-28 sandbox audit. The Local→Docker upgrade path stays gated on
   [in_playground] because that branch is opt-in via DockerPlayground —
   only the down-conversion (Docker→Local) is removed. *)
let effective_sandbox_profile ~(meta : keeper_meta) ~in_playground =
  if Env_config_keeper.KeeperSandbox.hard_mode () then
    (meta.sandbox_profile, meta.network_mode)
  else
    match meta.sandbox_profile with
    | Docker ->
        (* Invariant: meta=Docker → effective=Docker. No silent host fallback. *)
        (Docker, meta.network_mode)
    | Local
      when Env_config_keeper.DockerPlayground.enabled && in_playground ->
        (* Opt-in upgrade: Local→Docker only when the playground feature is
           enabled and the cwd is inside the playground root. *)
        (Docker, Network_inherit)
    | Local ->
        (Local, meta.network_mode)

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

type shell_guard_token =
  | Guard_word of string * bool
  | Guard_separator

let shell_guard_tokens cmd =
  let flush_word acc buf quoted =
    if Buffer.length buf = 0 then acc
    else begin
      let word = Buffer.contents buf |> String.lowercase_ascii in
      Buffer.clear buf;
      Guard_word (word, quoted) :: acc
    end
  in
  let len = String.length cmd in
  let rec loop i quote quoted acc buf =
    if i >= len then
      List.rev (flush_word acc buf quoted)
    else
      match quote, cmd.[i] with
      | Some q, c when c = q ->
          loop (i + 1) None true acc buf
      | Some _, c ->
          Buffer.add_char buf c;
          loop (i + 1) quote quoted acc buf
      | None, ('\'' | '"' as q) ->
          loop (i + 1) (Some q) true acc buf
      | None, (' ' | '\t' | '\r' | '\n') ->
          let acc = flush_word acc buf quoted in
          loop (i + 1) None false acc buf
      | None, (';' | '|') ->
          let acc = Guard_separator :: flush_word acc buf quoted in
          loop (i + 1) None false acc buf
      | None, '&' ->
          let acc =
            if i + 1 < len && cmd.[i + 1] = '&' then
              Guard_separator :: flush_word acc buf quoted
            else
              flush_word acc buf quoted
          in
          loop (if i + 1 < len && cmd.[i + 1] = '&' then i + 2 else i + 1)
            None false acc buf
      | None, c ->
          Buffer.add_char buf c;
          loop (i + 1) None quoted acc buf
  in
  loop 0 None false [] (Buffer.create 32)

let shell_assignment_like word =
  match String.index_opt word '=' with
  | None | Some 0 -> false
  | Some idx ->
      let ok_char = function
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
        | _ -> false
      in
      String.for_all ok_char (String.sub word 0 idx)

let command_word_mentions_nested_runtime cmd =
  let rec scan expect_command in_env = function
    | [] -> false
    | Guard_separator :: rest -> scan true false rest
    | Guard_word (word, quoted) :: rest ->
        if expect_command then
          if (not quoted) && List.mem word nested_container_runtime_tokens then
            true
          else if (not quoted) && (word = "sudo" || word = "command" || word = "time")
          then
            scan true false rest
          else if (not quoted) && word = "env" then
            scan true true rest
          else if in_env && (not quoted) && shell_assignment_like word then
            scan true true rest
          else
            scan false false rest
        else
          scan false false rest
  in
  scan true false (shell_guard_tokens cmd)

let command_uses_nested_container_runtime cmd =
  let lowered_cmd = String.lowercase_ascii cmd in
  command_word_mentions_nested_runtime cmd
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

let resolve_sandbox_root_git_cwd ~(config : Coord.config)
    ~(meta : keeper_meta) ~cwd ~cmd =
  let host_root =
    keeper_playground_root ~config ~meta
    |> Keeper_alerting_path.normalize_path_for_check
    |> Keeper_alerting_path.strip_trailing_slashes
  in
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
          try
            Sys.is_directory p
            && Sys.file_exists (Filename.concat p ".git")
          with Sys_error _ -> false)
        |> List.sort compare
      with Sys_error _ -> []
  in
  if cwd_normalized = host_root && cmd_targets_gh cmd
     && Keeper_gh_shared.has_repo_flag cmd
  then (cwd, None)
  else if cwd_normalized = host_root && cmd_targets_git_or_gh cmd then
    match repos_in_playground () with
    | [single_repo] ->
      (Filename.concat (Filename.concat host_root "repos") single_repo, None)
    | [] ->
      ( cwd,
        Some
          (Printf.sprintf
             "sandbox root cannot run git/gh: mount point %s is not a git repository and no sandbox git clones exist under repos/. First clone a repo with keeper_shell op=git_clone path=\"repos/<repo>\", then retry with cwd=\"repos/<repo>\" or cwd=\"repos/<repo>/.worktrees/<task>\"."
             host_root) )
    | example_repo :: _ as many ->
      (* #10680: keeper-executor-agent saw 17 events / 5min in a single
         session (mcp_VHsjtow_92C_2a0o, 2026-04-26 08:00→08:06) where
         the LLM read this descriptive error and still re-issued the
         same bare git/gh in the next turn. Make the message
         self-correcting: include the original cmd and the exact
         next-call shape so the LLM can copy-paste rather than
         re-derive the cwd convention from prose. *)
      let cmd_preview =
        let s = String.trim cmd in
        if String.length s > 120 then String.sub s 0 117 ^ "..." else s
      in
      ( cwd,
        Some
          (Printf.sprintf
             "sandbox root cannot run git/gh: mount point %s is not a git repository and multiple sandbox repos exist. Set cwd explicitly before retrying. Example next call: keeper_bash { \"cmd\": %S, \"cwd\": \"repos/%s\" }. Available repos: %s. Do not retry the same cmd from sandbox root."
             host_root cmd_preview example_repo (String.concat ", " many)) )
  else
    (cwd, None)

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

let safe_readdir dir =
  try
    if Sys.file_exists dir && Sys.is_directory dir then
      Sys.readdir dir |> Array.to_list
    else []
  with Sys_error _ -> []

let is_regular_file path =
  try (Unix.stat path).Unix.st_kind = Unix.S_REG with
  | Unix.Unix_error _ | Sys_error _ -> false

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) @@ fun () ->
  output_string oc content

let replace_all ~needle ~replacement source =
  if needle = "" then source
  else
    let needle_len = String.length needle in
    let source_len = String.length source in
    let buf = Buffer.create source_len in
    let rec loop i =
      if i >= source_len then ()
      else if i + needle_len <= source_len
              && String.sub source i needle_len = needle
      then begin
        Buffer.add_string buf replacement;
        loop (i + needle_len)
      end else begin
        Buffer.add_char buf source.[i];
        loop (i + 1)
      end
    in
    loop 0;
    Buffer.contents buf

let container_worktree_gitdir_candidates ~host_root =
  let repos_dir = Filename.concat host_root "repos" in
  safe_readdir repos_dir
  |> List.concat_map (fun repo_name ->
    let repo_root = Filename.concat repos_dir repo_name in
    if not (Sys.file_exists repo_root && Sys.is_directory repo_root) then []
    else
      let worktree_gitfiles =
        let worktrees_dir = Filename.concat repo_root ".worktrees" in
        safe_readdir worktrees_dir
        |> List.map (fun name ->
          Filename.concat (Filename.concat worktrees_dir name) ".git")
      in
      let admin_gitdirs =
        let admin_worktrees =
          Filename.concat (Filename.concat repo_root ".git") "worktrees"
        in
        safe_readdir admin_worktrees
        |> List.map (fun name ->
          Filename.concat (Filename.concat admin_worktrees name) "gitdir")
      in
      worktree_gitfiles @ admin_gitdirs)

let repair_container_worktree_gitdirs ~host_root ~container_root =
  container_worktree_gitdir_candidates ~host_root
  |> List.fold_left
       (fun repaired path ->
         if not (is_regular_file path) then repaired
         else
           try
             let before = read_file path in
             let after =
               replace_all ~needle:container_root ~replacement:host_root before
             in
             if String.equal before after then repaired
             else begin
               write_file path after;
               repaired + 1
             end
           with
           | Sys_error _ | End_of_file -> repaired)
       0

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
  let image =
    match meta.sandbox_image with
    | Some img when String.trim img <> "" -> img
    | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
  in
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
  else
    let cmd = rewrite_docker_command_paths ~config ~meta cmd in
  if command_uses_nested_container_runtime cmd then
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
         - 0 repo → explicit error로 clone/cwd 복구 액션 학습 *)
      let cwd, multi_repo_blocker =
        resolve_sandbox_root_git_cwd ~config ~meta ~cwd ~cmd
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
      match
        Keeper_sandbox_runtime.docker_user_identity_mount_args
          ~host_root ~uid ~gid
      with
      | Error err -> sandbox_error err
      | Ok identity_mounts ->
      let network_args, network_label =
        if git_creds_enabled then
          ([ "--network"; "bridge" ], "bridge")
        else
          Keeper_sandbox_runtime.docker_network_args network_mode
      in
      let cred_result =
        if not git_creds_enabled then
          Ok ([], [])
        else
          (* Credential composition is centralised in
             [Host_config_provider.resolve].  It selects either the
             keeper's explicit GitHub identity bundle or the MASC-owned
             root bundle.  Ambient operator GH_TOKEN/GITHUB_TOKEN,
             ~/.config/gh, ~/.ssh, and keychain probes are not part of
             keeper execution. *)
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
        @ Keeper_sandbox_runtime.docker_user_env_args ()
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
        @ identity_mounts
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
             (docker_exec_failure_message ~image ~status ~output)
         else begin
           if git_creds_enabled
              && String_util.contains_substring_ci cmd "git worktree"
           then
             let repaired =
               repair_container_worktree_gitdirs ~host_root ~container_root
             in
             if repaired > 0 then
               Log.Keeper.info
                 "%s: repaired %d docker worktree gitdir path(s) under %s"
                 meta.name repaired host_root;
           Keeper_registry.clear_error ~base_path:config.base_path meta.name;
         end;
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
  let image =
    match meta.sandbox_image with
    | Some img when String.trim img <> "" -> img
    | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
  in
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
    let cwd, sandbox_root_git_blocker =
      resolve_sandbox_root_git_cwd ~config ~meta ~cwd ~cmd
    in
    match sandbox_root_git_blocker with
    | Some message -> sandbox_error_json message
    | None ->
      let _ = turn_sandbox_runtime in
      match
        run_docker_shell_command_with_status ~config ~meta ~cwd ~timeout_sec
          ~cmd ~git_creds_enabled:true ~network_mode:Network_inherit
      with
      | Error message -> error_json message
      | Ok result ->
        let cwd_response =
          Keeper_cwd_response.docker
            ~host_cwd:cwd
            ~container_cwd:(docker_private_workspace_cwd ~config ~meta cwd)
        in
        Yojson.Safe.to_string
          (`Assoc
             ([
               ("ok", `Bool (result.status = Unix.WEXITED 0));
               ("via", `String "docker");
               ("cwd", Keeper_cwd_response.to_yojson_response cwd_response);
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
  let image =
    match meta.sandbox_image with
    | Some img when String.trim img <> "" -> img
    | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
  in
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
    let cwd, sandbox_root_git_blocker =
      resolve_sandbox_root_git_cwd ~config ~meta ~cwd ~cmd
    in
    match sandbox_root_git_blocker with
    | Some message -> sandbox_error_json message
    | None ->
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
             (docker_exec_failure_message ~image ~status:st ~output:out)
         else
           Keeper_registry.clear_error ~base_path:config.base_path meta.name;
         let cwd_response =
           Keeper_cwd_response.docker
             ~host_cwd:cwd
             ~container_cwd:
               (Keeper_turn_sandbox_runtime.container_cwd_of_host runtime
                  ~host_cwd:cwd)
         in
         Yojson.Safe.to_string
           (`Assoc
              ([
                ("ok", `Bool (st = Unix.WEXITED 0));
                ("via", `String "docker");
                ("cwd", Keeper_cwd_response.to_yojson_response cwd_response);
                ("sandbox_profile", `String "docker");
                ("git_creds_enabled", `Bool false);
                ("network_mode", `String (network_mode_to_string network_mode));
                ("effective_sandbox_image", `String image);
                ("status", Keeper_alerting_path.process_status_to_json st);
                ("output", `String out);
              ] @ gh_exit_class_field ~cmd ~status:st ~output:out)))
    | _ ->
      (match turn_sandbox_runtime with
       | Some _ ->
         Prometheus.inc_counter
           Prometheus.metric_keeper_docker_runtime_discarded
           ~labels:[ ("keeper", meta.name); ("reason", "network_mode_mismatch") ]
           ()
       | None -> ());
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
        let cwd_response =
          Keeper_cwd_response.docker
            ~host_cwd:cwd
            ~container_cwd:(docker_private_workspace_cwd ~config ~meta cwd)
        in
        Yojson.Safe.to_string
          (`Assoc
             ([
               ("ok", `Bool (result.status = Unix.WEXITED 0));
               ("via", `String "docker");
               ("cwd", Keeper_cwd_response.to_yojson_response cwd_response);
               ("sandbox_profile", `String "docker");
               ("git_creds_enabled", `Bool false);
               ("network_mode", `String result.network_label);
               ("effective_sandbox_image", `String result.image);
               ( "status",
                 Keeper_alerting_path.process_status_to_json result.status );
               ("output", `String result.output);
             ] @ gh_exit_class_field ~cmd ~status:result.status ~output:result.output)))

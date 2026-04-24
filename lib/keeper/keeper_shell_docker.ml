(** Docker/sandbox shell execution infrastructure.

    Extracted from keeper_exec_shell.ml — Docker container lifecycle,
    sandbox profile resolution, and container invocation functions.
    These are pure infrastructure; command dispatch remains in
    keeper_exec_shell.ml. *)

open Keeper_types
open Keeper_exec_shared

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
      Some (Masc_exec.Egress_policy.blocked_to_json blocked)

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
        ~base_path:config.base_path ~timeout_sec:2.0 ()
    in
    match ensure_keeper_sandbox_runtime ~timeout_sec with
    | Error err -> sandbox_error err
    | Ok seccomp_args ->
      let host_root =
        keeper_playground_root ~config ~meta
        |> Keeper_alerting_path.normalize_path_for_check
        |> Keeper_alerting_path.strip_trailing_slashes
      in
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
      let cred_root = "/tmp/keeper-creds" in
      let cred_result =
        if not git_creds_enabled then
          Ok ([], [])
        else
          match Keeper_gh_env.keeper_binding config ~keeper_name:meta.name with
          | Error err -> Error err
          | Ok binding ->
            let gh_creds =
              match binding.gh_config_dir with
              | Some dir -> dir
              | None ->
                  Env_config_keeper.KeeperSandbox.gh_creds_host_path ()
            in
            let gitconfig = Env_config_keeper.KeeperSandbox.gitconfig_host_path () in
            let ssh_dir = Env_config_keeper.KeeperSandbox.ssh_dir_host_path () in
            let mounts =
              optional_ro_mount ~host:gh_creds
                ~container:(Filename.concat cred_root ".config/gh")
              @ optional_ro_mount ~host:gitconfig
                  ~container:(Filename.concat cred_root ".gitconfig")
              @ optional_ro_mount ~host:ssh_dir
                  ~container:(Filename.concat cred_root ".ssh")
            in
            let git_author_name, git_author_email =
              match binding with
              | { github_identity = Some id; git_identity_mode = "github_identity"; _ } ->
                  id, id ^ "@users.noreply.github.com"
              | _ ->
                  ( Keeper_identity.keeper_git_author
                      ~keeper_name:meta.name,
                    Keeper_identity.keeper_git_email
                      ~keeper_name:meta.name )
            in
            let git_identity_env ~name ~email =
              [
                "-e"; "GIT_AUTHOR_NAME=" ^ name;
                "-e"; "GIT_AUTHOR_EMAIL=" ^ email;
                "-e"; "GIT_COMMITTER_NAME=" ^ name;
                "-e"; "GIT_COMMITTER_EMAIL=" ^ email;
              ]
            in
            let envs =
              [
                "-e"; "HOME=" ^ cred_root;
                "-e"; "GH_CONFIG_DIR=" ^ Filename.concat cred_root ".config/gh";
                "-e"; "GIT_CONFIG_GLOBAL=" ^ Filename.concat cred_root ".gitconfig";
                "-e"; "GIT_CONFIG_COUNT=1";
                "-e"; "GIT_CONFIG_KEY_0=safe.directory";
                "-e"; "GIT_CONFIG_VALUE_0=*";
              ]
              @ git_identity_env ~name:git_author_name ~email:git_author_email
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
              [
                ("ok", `Bool (st = Unix.WEXITED 0));
                ("via", `String "docker");
                ("cwd", `String cwd);
                ("sandbox_profile", `String "docker");
                ("git_creds_enabled", `Bool true);
                ("network_mode", `String (network_mode_to_string Network_inherit));
                ("effective_sandbox_image", `String image);
                ("status", Keeper_alerting_path.process_status_to_json st);
                ("output", `String out);
              ]))
    | None ->
      match
        run_docker_shell_command_with_status ~config ~meta ~cwd ~timeout_sec
          ~cmd ~git_creds_enabled:true ~network_mode:Network_inherit
      with
      | Error message -> error_json message
      | Ok result ->
        Yojson.Safe.to_string
          (`Assoc
             [
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
             ]))

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
              [
                ("ok", `Bool (st = Unix.WEXITED 0));
                ("via", `String "docker");
                ("cwd", `String cwd);
                ("sandbox_profile", `String "docker");
                ("git_creds_enabled", `Bool false);
                ("network_mode", `String (network_mode_to_string network_mode));
                ("effective_sandbox_image", `String image);
                ("status", Keeper_alerting_path.process_status_to_json st);
                ("output", `String out);
              ]))
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
             [
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
             ]))

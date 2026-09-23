module Github = Keeper_github_identity
module Secret_projection = Keeper_secret_projection

let process_status_to_string = function
  | Unix.WEXITED n -> Printf.sprintf "WEXITED %d" n
  | Unix.WSIGNALED n -> Printf.sprintf "WSIGNALED %d" n
  | Unix.WSTOPPED n -> Printf.sprintf "WSTOPPED %d" n
;;

let process_status_testable =
  Alcotest.testable
    (fun fmt s -> Format.pp_print_string fmt (process_status_to_string s))
    (fun a b -> a = b)
;;

let rec mkdir_p path =
  if Sys.file_exists path
  then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700
  end
;;

let write_file path content =
  mkdir_p (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> In_channel.input_all channel)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stats ->
    (match stats.Unix.st_kind with
     | Unix.S_DIR ->
       Sys.readdir path
       |> Array.iter (fun name -> remove_tree (Filename.concat path name));
       Unix.rmdir path
     | _ -> Unix.unlink path)
;;

let with_temp_base run =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-keeper-github-%d-%.0f" (Unix.getpid ()) (Unix.gettimeofday () *. 1_000_000.))
  in
  mkdir_p base_path;
  mkdir_p (Common.keepers_runtime_dir_of_base ~base_path);
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () -> run base_path config)
;;

let env_value name env =
  let prefix = name ^ "=" in
  Array.to_list env
  |> List.find_map (fun entry ->
    if String.starts_with ~prefix entry
    then Some (String.sub entry (String.length prefix) (String.length entry - String.length prefix))
    else None)
;;

let test_pure_environment_contract () =
  let input =
    [| "PATH=/bin"
     ; "GH_CONFIG_DIR=/host/default"
     ; "GH_TOKEN=one"
     ; "GITHUB_TOKEN=two"
     ; "GH_ENTERPRISE_TOKEN=three"
     ; "GITHUB_ENTERPRISE_TOKEN=four"
     ; "KEEP=value"
    |]
  in
  let configured = Github.overlay_config_env ~config_dir:"/keeper/github" input in
  Alcotest.(check (option string)) "keeper config wins" (Some "/keeper/github")
    (env_value "GH_CONFIG_DIR" configured);
  Alcotest.(check (option string)) "projected config is recoverable"
    (Some "/keeper/github")
    (Github.projected_config_dir configured);
  Alcotest.(check (option string)) "unrelated env preserved" (Some "value")
    (env_value "KEEP" configured);
  let stripped = Github.strip_github_token_env configured in
  List.iter
    (fun name ->
       Alcotest.(check (option string)) (name ^ " removed") None (env_value name stripped))
    [ "GH_TOKEN"; "GITHUB_TOKEN"; "GH_ENTERPRISE_TOKEN"; "GITHUB_ENTERPRISE_TOKEN" ];
  Alcotest.(check (list string)) "projected token names are exact"
    [ "GH_TOKEN"; "GITHUB_TOKEN"; "GH_ENTERPRISE_TOKEN"; "GITHUB_ENTERPRISE_TOKEN" ]
    (Github.projected_token_env_names configured)
;;

let fake_gh_script =
  {|#!/bin/sh
set -eu
if [ -n "${KEEP_SECRET-}" ]; then
  echo "unrelated Keeper secret leaked into GitHub CLI" >&2
  exit 42
fi
case "${1-}:${2-}" in
  auth:login)
    if [ -n "${GH_TOKEN-}${GITHUB_TOKEN-}${GH_ENTERPRISE_TOKEN-}${GITHUB_ENTERPRISE_TOKEN-}" ]; then
      echo "token leaked into login" >&2
      exit 41
    fi
    printf '%s\n' "$@" > "$GH_CONFIG_DIR/login-args"
    for arg in "$@"; do
      if [ "$arg" = "--with-token" ]; then
        cat > "$GH_CONFIG_DIR/received-token"
      fi
    done
    printf '%s\n' "stored-user" > "$GH_CONFIG_DIR/stored-login"
    printf '%s\n' "github.com:" "  user: stored-user" "  oauth_token: fixture-token" > "$GH_CONFIG_DIR/hosts.yml"
    ;;
  api:--hostname)
    # [--include] puts the status line and headers first, as real gh does.
    # The projected token answers like a fine-grained PAT: no scopes header.
    if [ -n "${GH_TOKEN-}" ]; then
      printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n%s\n' "token-user"
    elif [ -f "$GH_CONFIG_DIR/stored-login" ]; then
      printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: gist, read:org, repo, workflow\r\n\r\n'
      cat "$GH_CONFIG_DIR/stored-login"
    else
      echo "not authenticated" >&2
      exit 4
    fi
    ;;
  *)
    echo "unexpected fake gh argv: $*" >&2
    exit 64
    ;;
esac
|}
;;

let test_fake_gh_login_and_effective_identity () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "github-test-keeper" in
  let fake_bin = Filename.concat base_path "fake-bin" in
  let fake_gh = Filename.concat fake_bin "gh" in
  write_file fake_gh fake_gh_script;
  Unix.chmod fake_gh 0o700;
  let secret_root = Secret_projection.secret_root ~base_path ~keeper_name in
  write_file (Filename.concat (Filename.concat secret_root "env") "GH_TOKEN") "projected-token\n";
  write_file
    (Filename.concat (Filename.concat secret_root "env") "KEEP_SECRET")
    "must-not-reach-github-cli\n";
  write_file
    (Filename.concat (Filename.concat secret_root "env") "PATH")
    "/keeper-controlled-path-must-not-run-gh\n";
  let previous_path = Sys.getenv "PATH" in
  Unix.putenv "PATH" (fake_bin ^ ":" ^ previous_path);
  Fun.protect
    ~finally:(fun () -> Unix.putenv "PATH" previous_path)
    (fun () ->
       (match Github.local_lane ~config ~keeper_name ~hostname:"github.com" with
        | Error message -> Alcotest.fail message
        | Ok lane ->
          Alcotest.(check int) "fake login exits successfully" 0
            (Github.run_cli_login ~lane ~scopes:[]));
       let keeper_config = Github.config_dir ~config ~keeper_name in
       let login_args = read_file (Filename.concat keeper_config "login-args") in
       Alcotest.(check bool) "web login argv reached fake gh" true
         (String.contains login_args '\n'
          && String.ends_with ~suffix:"--insecure-storage\n" login_args);
       match Github.observe ~config ~keeper_name ~hostname:"github.com" with
       | Error message -> Alcotest.fail message
       | Ok observation ->
         Alcotest.(check (option string)) "stored identity uses Keeper config"
           (Some "stored-user") observation.stored.login;
         Alcotest.(check (option string)) "effective identity uses projected token"
           (Some "token-user") observation.effective.login;
         Alcotest.(check (option (list string))) "stored token scopes come from the header"
           (Some [ "gist"; "read:org"; "repo"; "workflow" ]) observation.stored.scopes;
         Alcotest.(check (option (list string)))
           "a token GitHub lists no scopes for is not given an empty list"
           None observation.effective.scopes;
         Alcotest.(check (list string)) "effective token source is observable by name"
           [ "GH_TOKEN" ] observation.projected_token_env_names;
         Alcotest.(check string) "effective probe is explicitly host-scoped"
           "host_process_credential_only"
           (match observation.effective_probe_scope with
            | `Host_process_credential_only -> "host_process_credential_only"
            | `Endpoint_process_only -> "endpoint_process_only"))
;;

let test_fake_gh_set_token () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "github-token-keeper" in
  let fake_bin = Filename.concat base_path "fake-bin" in
  let fake_gh = Filename.concat fake_bin "gh" in
  write_file fake_gh fake_gh_script;
  Unix.chmod fake_gh 0o700;
  let previous_path = Sys.getenv "PATH" in
  Unix.putenv "PATH" (fake_bin ^ ":" ^ previous_path);
  Fun.protect
    ~finally:(fun () -> Unix.putenv "PATH" previous_path)
    (fun () ->
       let expected_argv =
         Github.login_with_token_argv ~hostname:"github.com"
       in
       Alcotest.(check (list string)) "login_with_token_argv structure"
         [ "gh"; "auth"; "login"; "--hostname"; "github.com"; "--git-protocol"; "https"; "--insecure-storage"; "--with-token" ]
         expected_argv;
       match Github.local_lane ~config ~keeper_name ~hostname:"github.com" with
       | Error message -> Alcotest.fail message
       | Ok lane ->
         (match Github.set_token ~lane ~base_path ~keeper_name ~token:"github_pat_fixture_secret" with
          | Error message -> Alcotest.fail message
          | Ok observation ->
            let keeper_config = Github.config_dir ~config ~keeper_name in
            let login_args = read_file (Filename.concat keeper_config "login-args") in
            Alcotest.(check bool) "--with-token passed in argv" true
              (String.contains login_args '\n'
               && String.ends_with ~suffix:"--with-token\n" login_args);
            let received_token = read_file (Filename.concat keeper_config "received-token") in
            Alcotest.(check string) "token passed via stdin" "github_pat_fixture_secret" received_token;
            Alcotest.(check (option string)) "stored identity updated"
              (Some "stored-user") observation.stored.login);
         Alcotest.(check int) "run_cli_set_token exits 0" 0
           (Github.run_cli_set_token ~lane ~base_path ~keeper_name ~token:"github_pat_second_secret"))
;;

let test_config_dir_does_not_chmod_ancestor () =
  with_temp_base @@ fun base_path config ->
  Unix.chmod base_path 0o755;
  (match Github.ensure_config_dir ~config ~keeper_name:"mode-test" with
   | Error message -> Alcotest.fail message
   | Ok _ -> ());
  let mode = (Unix.stat base_path).Unix.st_perm land 0o777 in
  Alcotest.(check int) "workspace mode is unchanged" 0o755 mode
;;

let test_config_dir_is_cluster_scoped () =
  with_temp_base @@ fun base_path default_config ->
  let config =
    { default_config with
      backend_config = { Workspace.cluster_name = "identity-cluster" }
    }
  in
  mkdir_p (Workspace.keepers_runtime_dir config);
  let keeper_name = "same-name" in
  let cluster_path = Github.config_dir ~config ~keeper_name in
  let default_path = Github.config_dir ~config:default_config ~keeper_name in
  Alcotest.(check bool) "cluster identity is not the default identity" true
    (not (String.equal cluster_path default_path));
  (match Github.ensure_config_dir ~config ~keeper_name with
   | Error message -> Alcotest.fail message
   | Ok path -> Alcotest.(check string) "cluster path is authoritative" cluster_path path);
  Alcotest.(check bool) "default cluster identity remains absent" false
    (Sys.file_exists default_path)
;;

let test_config_dir_rejects_symlink () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "directory-symlink-test" in
  let keeper_root =
    Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
  in
  mkdir_p keeper_root;
  let target = Filename.concat base_path "redirected-config" in
  mkdir_p target;
  Unix.symlink target (Github.config_dir ~config ~keeper_name);
  match Github.ensure_config_dir ~config ~keeper_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "symbolic-link GitHub config directory was accepted"
;;

let test_config_dir_rejects_credential_symlink () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "credential-symlink-test" in
  let config_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let target = Filename.concat base_path "redirected-hosts.yml" in
  write_file target "oauth_token: do-not-touch\n";
  Unix.symlink target (Filename.concat config_dir "hosts.yml");
  match Github.ensure_config_dir ~config ~keeper_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "symbolic-link GitHub credential file was accepted"
;;

let docker_projection ~config ~keeper_name =
  Github.docker_args_for_tool
    ~config
    ~keeper_name
    ~container_masc_dir:"/tmp/masc-runtime/.masc"
;;

let test_tool_projection_is_nonblocking_without_identity () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "missing-identity" in
  let docker_projection =
    match
      Github.docker_args_for_tool
        ~config
        ~keeper_name
        ~container_masc_dir:"/tmp/masc-runtime/.masc"
    with
    | Error message -> Alcotest.fail message
    | Ok projection -> projection
  in
  (match docker_projection.identity_state with
   | Github.Unconfigured -> ()
   | Configured _ -> Alcotest.fail "missing Docker identity reported configured");
  let host_dir = Github.config_dir ~config ~keeper_name in
  let first_snapshot = docker_projection.host_snapshot_dir in
  Alcotest.(check bool) "read-only empty snapshot exists" true
    (Sys.file_exists first_snapshot && Sys.is_directory first_snapshot);
  Alcotest.(check bool) "missing host identity remains unprovisioned" false
    (Sys.file_exists host_dir);
  Alcotest.(check (list string))
    "an unconfigured keeper still commits under its name; config is read-only"
    [ "--env"
    ; "GIT_AUTHOR_NAME=missing-identity"
    ; "--env"
    ; "GIT_COMMITTER_NAME=missing-identity"
    ; "--env"
    ; "GH_CONFIG_DIR=/tmp/masc-runtime/.masc/keepers/missing-identity/github-cli"
    ; "-v"
    ; first_snapshot
      ^ ":/tmp/masc-runtime/.masc/keepers/missing-identity/github-cli:ro"
    ]
    docker_projection.args;
  let host_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let hosts = Filename.concat host_dir "hosts.yml" in
  write_file hosts "github.com:\n  user: first-login\n  oauth_token: first-token\n";
  Unix.chmod hosts 0o600;
  Alcotest.(check bool) "running snapshot cannot see later login" false
    (Sys.file_exists (Filename.concat first_snapshot "hosts.yml"));
  let after_login_projection =
    match
      Github.docker_args_for_tool
        ~config
        ~keeper_name
        ~container_masc_dir:"/tmp/masc-runtime/.masc"
    with
    | Error message -> Alcotest.fail message
    | Ok projection -> projection
  in
  (match after_login_projection.identity_state with
   | Github.Configured path ->
     Alcotest.(check string) "next dispatch observes the host identity" host_dir path
   | Unconfigured -> Alcotest.fail "first login remained unconfigured");
  let after_login_snapshot = after_login_projection.host_snapshot_dir in
  Alcotest.(check bool) "next dispatch gets a distinct snapshot" true
    (not (String.equal first_snapshot after_login_snapshot));
  Alcotest.(check string) "next snapshot contains the login state"
    "github.com:\n  user: first-login\n  oauth_token: first-token\n"
    (read_file (Filename.concat after_login_snapshot "hosts.yml"));
  docker_projection.cleanup ();
  after_login_projection.cleanup ();
  Alcotest.(check bool) "empty Docker snapshot is cleaned" false
    (Sys.file_exists first_snapshot);
  Alcotest.(check bool) "configured Docker snapshot is cleaned" false
    (Sys.file_exists after_login_snapshot)
;;

let test_empty_existing_identity_remains_unconfigured () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "empty-existing-identity" in
  let host_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let hosts = Filename.concat host_dir "hosts.yml" in
  let assert_unconfigured label content =
    write_file hosts content;
    Unix.chmod hosts 0o600;
    let projection =
      match docker_projection ~config ~keeper_name with
      | Error message -> Alcotest.fail message
      | Ok projection -> projection
    in
    Fun.protect ~finally:projection.Github.cleanup @@ fun () ->
    match projection.Github.identity_state with
    | Github.Unconfigured -> ()
    | Configured _ -> Alcotest.fail (label ^ " reported configured")
  in
  assert_unconfigured "zero-byte hosts.yml" "";
  assert_unconfigured "post-logout empty mapping" "{}\n";
  assert_unconfigured
    "host metadata without a credential"
    "github.com:\n  user: logged-out-user\n  git_protocol: https\n";
  assert_unconfigured
    "empty account credential"
    "github.com:\n  users:\n    logged-out-user:\n      oauth_token: \"\"\n"
;;

let test_malformed_hosts_yaml_is_rejected () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "malformed-hosts-yaml" in
  let host_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let hosts = Filename.concat host_dir "hosts.yml" in
  write_file hosts "github.com\n";
  Unix.chmod hosts 0o600;
  match docker_projection ~config ~keeper_name with
  | Error _ -> ()
  | Ok projection ->
    projection.Github.cleanup ();
    Alcotest.fail "malformed hosts.yml was collapsed into unconfigured state"
;;

let test_local_snapshot_cleanup_does_not_follow_replacement_symlink () =
  with_temp_base @@ fun base_path config ->
  let projection =
    match docker_projection ~config ~keeper_name:"cleanup-symlink" with
    | Error message -> Alcotest.fail message
    | Ok projection -> projection
  in
  let cleanup = projection.Github.cleanup in
  let snapshot = projection.Github.host_snapshot_dir in
  let target = Filename.concat base_path "cleanup-target" in
  Unix.mkdir target 0o755;
  Unix.chmod snapshot 0o700;
  Unix.rmdir snapshot;
  Unix.symlink target snapshot;
  cleanup ();
  Alcotest.(check int) "replacement target mode is unchanged" 0o755
    ((Unix.stat target).Unix.st_perm land 0o777);
  Alcotest.(check bool) "replacement symlink is removed" false
    (match Unix.lstat snapshot with
     | _ -> true
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false)
;;

let test_observe_does_not_provision_missing_identity () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "observe-missing-identity" in
  let config_dir = Github.config_dir ~config ~keeper_name in
  Alcotest.(check bool) "identity starts absent" false (Sys.file_exists config_dir);
  (match Github.observe ~config ~keeper_name ~hostname:"github.com" with
   | Error message -> Alcotest.fail message
   | Ok observation ->
     Alcotest.(check bool) "stored identity is unconfigured" false
       observation.stored.authenticated;
     Alcotest.(check bool) "effective identity is unconfigured" false
       observation.effective.authenticated);
  Alcotest.(check bool) "observation remains read-only" false
    (Sys.file_exists config_dir)
;;

let commit_name_args keeper_name =
  [ "--env"
  ; "GIT_AUTHOR_NAME=" ^ keeper_name
  ; "--env"
  ; "GIT_COMMITTER_NAME=" ^ keeper_name
  ]
;;

let test_persistent_container_commits_under_the_keeper_name_without_login () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "persistent-unconfigured" in
  match
    Github.docker_args_persistent
      ~config
      ~keeper_name
      ~container_masc_dir:"/tmp/masc-runtime/.masc"
  with
  | Error message -> Alcotest.fail message
  | Ok args ->
    Alcotest.(check (list string))
      "a keeper with no GitHub login gets only its commit names"
      (commit_name_args keeper_name)
      args
;;

let test_persistent_container_commits_under_the_keeper_name_with_login () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "persistent-configured" in
  let host_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let hosts = Filename.concat host_dir "hosts.yml" in
  write_file hosts "github.com:\n  user: stored-user\n  oauth_token: stored-token\n";
  Unix.chmod hosts 0o600;
  let container_masc_dir = "/tmp/masc-runtime/.masc" in
  let container_dir = Github.container_config_dir ~container_masc_dir ~keeper_name in
  match Github.docker_args_persistent ~config ~keeper_name ~container_masc_dir with
  | Error message -> Alcotest.fail message
  | Ok args ->
    Alcotest.(check (list string))
      "commit names, then the live config mount and its git wiring"
      (commit_name_args keeper_name
       @ [ "--env"
         ; "GH_CONFIG_DIR=" ^ container_dir
         ; "-v"
         ; host_dir ^ ":" ^ container_dir ^ ":ro"
         ; "--env"
         ; "GIT_CONFIG_GLOBAL=" ^ Filename.concat container_dir "gitconfig"
         ])
      args
;;

let test_tool_projection_uses_safe_existing_identity () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "configured-identity" in
  let host_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let hosts = Filename.concat host_dir "hosts.yml" in
  write_file
    hosts
    "github.com:\n  user: stored-user\n  users:\n    stored-user:\n      oauth_token: stored-token\n";
  Unix.chmod hosts 0o600;
  let container_masc_dir = "/tmp/masc-runtime/.masc" in
  let container_dir = Github.container_config_dir ~container_masc_dir ~keeper_name in
  let docker_projection =
    match Github.docker_args_for_tool ~config ~keeper_name ~container_masc_dir with
    | Error message -> Alcotest.fail message
    | Ok projection -> projection
  in
  (match docker_projection.identity_state with
   | Github.Configured path -> Alcotest.(check string) "mounted path" host_dir path
   | Unconfigured -> Alcotest.fail "existing Docker identity reported unconfigured");
  let docker_snapshot = docker_projection.host_snapshot_dir in
  Alcotest.(check bool) "Docker never receives the operator-owned path" true
    (not (String.equal docker_snapshot host_dir));
  Alcotest.(check (list string))
    "commit names are the keeper's; safe identity snapshot is mounted read-only"
    [ "--env"
    ; "GIT_AUTHOR_NAME=" ^ keeper_name
    ; "--env"
    ; "GIT_COMMITTER_NAME=" ^ keeper_name
    ; "--env"
    ; "GH_CONFIG_DIR=" ^ container_dir
    ; "-v"
    ; docker_snapshot ^ ":" ^ container_dir ^ ":ro"
    ; "--env"
    ; "GIT_CONFIG_GLOBAL=" ^ Filename.concat container_dir "gitconfig"
    ]
    docker_projection.args;
  (* task-847: the snapshot carries the wiring [gh auth setup-git] would
     write, derived from the hosts this identity holds — git alone never
     reads hosts.yml, and without a helper an https push dies prompting for
     a username no sandbox terminal can answer. *)
  Alcotest.(check string) "the snapshot wires git to the gh credential helper"
    ("[credential \"https://github.com\"]\n\thelper = \n\thelper = !gh auth git-credential\n"
     ^ "[credential \"https://gist.github.com\"]\n\thelper = \n\thelper = !gh auth git-credential\n")
    (read_file (Filename.concat docker_snapshot "gitconfig"));
  write_file
    hosts
    "github.com:\n  user: changed-after-dispatch\n  users:\n    changed-after-dispatch:\n      oauth_token: changed-token\n";
  Alcotest.(check string) "Docker snapshot is immutable across host login changes"
    "github.com:\n  user: stored-user\n  users:\n    stored-user:\n      oauth_token: stored-token\n"
    (read_file (Filename.concat docker_snapshot "hosts.yml"));
  docker_projection.cleanup ();
  Alcotest.(check bool) "Docker snapshot is cleaned" false
    (Sys.file_exists docker_snapshot)
;;

let test_tool_projection_rejects_malformed_identity () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "malformed-identity" in
  let keeper_root =
    Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
  in
  mkdir_p keeper_root;
  let target = Filename.concat base_path "redirected-tool-config" in
  mkdir_p target;
  Unix.symlink target (Github.config_dir ~config ~keeper_name);
  match
    Github.docker_args_for_tool
      ~config
      ~keeper_name
      ~container_masc_dir:"/tmp/masc-runtime/.masc"
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "malformed Docker identity was collapsed into absence"
;;

let test_tool_projection_rejects_permissive_identity () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "permissive-identity" in
  let config_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  Unix.chmod config_dir 0o755;
  (match docker_projection ~config ~keeper_name with
   | Error _ -> ()
   | Ok projection ->
     projection.Github.cleanup ();
     Alcotest.fail "world-readable config directory was accepted");
  Unix.chmod config_dir 0o700;
  let hosts = Filename.concat config_dir "hosts.yml" in
  write_file hosts "github.com:\n  oauth_token: fixture\n";
  Unix.chmod hosts 0o644;
  match
    Github.docker_args_for_tool
      ~config
      ~keeper_name
      ~container_masc_dir:"/tmp/masc-runtime/.masc"
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "world-readable credential file was accepted"
;;

let write_hosts ~config ~keeper_name content =
  let config_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let hosts = Filename.concat config_dir "hosts.yml" in
  write_file hosts content;
  Unix.chmod hosts 0o600
;;

(* The shape `gh auth login --insecure-storage` writes: the token sits under
   the host. *)
let test_stored_token_reads_the_host_scalar () =
  with_temp_base @@ fun base_path config ->
  let keeper_name = "token-host" in
  write_hosts ~config ~keeper_name "github.com:\n  oauth_token: gho_fixture\n";
  match Github.stored_token ~config ~keeper_name ~hostname:"github.com" with
  | Error message -> Alcotest.fail message
  | Ok token -> Alcotest.(check string) "host scalar is the token" "gho_fixture" token
;;

(* The other shape the decoder admits: the token under the host's [users]
   mapping. Both are gh's, so both have to answer. *)
let test_stored_token_reads_the_users_scalar () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "token-users" in
  write_hosts
    ~config
    ~keeper_name
    "github.com:\n  users:\n    anyang-keepers:\n      oauth_token: gho_nested\n";
  match Github.stored_token ~config ~keeper_name ~hostname:"github.com" with
  | Error message -> Alcotest.fail message
  | Ok token -> Alcotest.(check string) "nested scalar is the token" "gho_nested" token
;;

(* Two hosts in one file is ordinary once an enterprise remote is added. The
   caller named one, so the other must not answer for it. *)
let test_stored_token_is_scoped_to_the_named_host () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "token-two-hosts" in
  write_hosts
    ~config
    ~keeper_name
    "github.com:\n  oauth_token: gho_public\n\
     ghe.example.com:\n  oauth_token: gho_enterprise\n";
  (match Github.stored_token ~config ~keeper_name ~hostname:"ghe.example.com" with
   | Error message -> Alcotest.fail message
   | Ok token -> Alcotest.(check string) "enterprise host" "gho_enterprise" token);
  match Github.stored_token ~config ~keeper_name ~hostname:"unlisted.example" with
  | Ok token -> Alcotest.fail ("an unlisted host answered with " ^ token)
  | Error _ -> ()
;;

(* Logged out, gh leaves `{}`. Reading that as a credential would send an
   empty bearer and read the provider's 401 as the provider being down. *)
let test_stored_token_refuses_a_logged_out_identity () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "token-logged-out" in
  write_hosts ~config ~keeper_name "{}\n";
  match Github.stored_token ~config ~keeper_name ~hostname:"github.com" with
  | Ok token -> Alcotest.fail ("a logged-out identity answered with " ^ token)
  | Error _ -> ()
;;

let test_stored_token_refuses_a_keeper_with_no_identity () =
  with_temp_base @@ fun _base_path config ->
  match Github.stored_token ~config ~keeper_name:"never-logged-in" ~hostname:"github.com" with
  | Ok token -> Alcotest.fail ("a keeper with no identity answered with " ^ token)
  | Error _ -> ()
;;

(* The reason masc keeps no copy: gh rewrites this file, and the next read has
   to be the new token rather than the one that was current at attach time. *)
let test_stored_token_follows_a_relogin () =
  with_temp_base @@ fun _base_path config ->
  let keeper_name = "token-relogin" in
  write_hosts ~config ~keeper_name "github.com:\n  oauth_token: gho_first\n";
  (match Github.stored_token ~config ~keeper_name ~hostname:"github.com" with
   | Error message -> Alcotest.fail message
   | Ok token -> Alcotest.(check string) "first login" "gho_first" token);
  write_hosts ~config ~keeper_name "github.com:\n  oauth_token: gho_second\n";
  match Github.stored_token ~config ~keeper_name ~hostname:"github.com" with
  | Error message -> Alcotest.fail message
  | Ok token -> Alcotest.(check string) "second login is what is read" "gho_second" token
;;

(* The login writes through the cluster-aware [config_dir]. The token read and
   the redaction file list have to name that same directory, or a non-default
   cluster's login reads as absent and its token goes unredacted. *)
let test_stored_token_reads_the_cluster_directory () =
  with_temp_base @@ fun base_path default_config ->
  let cluster_name = "token-cluster" in
  let config =
    { default_config with backend_config = { Workspace.cluster_name } }
  in
  mkdir_p (Workspace.keepers_runtime_dir config);
  let keeper_name = "token-cluster-keeper" in
  write_hosts ~config ~keeper_name "github.com:\n  oauth_token: gho_cluster\n";
  (match Github.stored_token ~config ~keeper_name ~hostname:"github.com" with
   | Error message -> Alcotest.fail message
   | Ok token -> Alcotest.(check string) "the cluster's login is read" "gho_cluster" token);
  (match Github.stored_token ~config:default_config ~keeper_name ~hostname:"github.com" with
   | Ok token -> Alcotest.fail ("the default cluster answered with " ^ token)
   | Error _ -> ());
  Unix.putenv "MASC_CLUSTER_NAME" cluster_name;
  Fun.protect ~finally:(fun () -> Unix.putenv "MASC_CLUSTER_NAME" "") @@ fun () ->
  Alcotest.(check (list string)) "the redaction file is the one the login wrote"
    [ Filename.concat (Github.config_dir ~config ~keeper_name) "hosts.yml" ]
    (Github.secret_files_of_base_path ~base_path ~keeper_name)
;;

let test_run_inherited_returns_child_exit_status () =
  let status = Github.run_inherited ~timeout_sec:10.0 ~env:[||] [ "sh"; "-c"; "exit 7" ] in
  Alcotest.(check process_status_testable)
    "child exit status is propagated" (Unix.WEXITED 7) status
;;

let test_run_inherited_times_out_hung_subprocess () =
  let started_at = Unix.gettimeofday () in
  let status = Github.run_inherited ~timeout_sec:0.3 ~env:[||] [ "sh"; "-c"; "sleep 30" ] in
  let elapsed = Unix.gettimeofday () -. started_at in
  Alcotest.(check process_status_testable)
    "hung subprocess is killed and reported as timed out" (Unix.WEXITED 124) status;
  Alcotest.(check bool) "timeout is enforced promptly" true (elapsed < 10.0)
;;

let test_run_inherited_empty_argv_is_127 () =
  let status = Github.run_inherited ~timeout_sec:10.0 ~env:[||] [] in
  Alcotest.(check process_status_testable)
    "empty argv yields 127" (Unix.WEXITED 127) status
;;

(* Without a chosen scope the argv is the one every login ran before scopes
   existed, so gh asks for its own minimum. A chosen scope becomes one
   [--scopes] argument, named once however often it was asked for. *)
let test_login_argv_carries_only_chosen_scopes () =
  let has_scopes argv = List.mem "--scopes" argv in
  Alcotest.(check bool)
    "no scope asks gh for nothing extra"
    false
    (has_scopes (Github.login_argv ~hostname:"github.com" ~scopes:[]));
  let argv =
    Github.login_argv ~hostname:"github.com" ~scopes:[ Github.Workflow; Github.Workflow ]
  in
  let rec after = function
    | "--scopes" :: value :: _ -> Some value
    | _ :: rest -> after rest
    | [] -> None
  in
  Alcotest.(check (option string)) "workflow is named once" (Some "workflow") (after argv);
  Alcotest.(check (option string))
    "two scopes are one argument, in the offered order"
    (Some "workflow,write:packages")
    (after
       (Github.login_argv
          ~hostname:"github.com"
          ~scopes:[ Github.Write_packages; Github.Workflow ]))
;;

(* The request names scopes by string. Every offered scope reads back as
   itself, and a name nobody offered is refused rather than dropped, so a
   surface that asked for it is told. *)
let test_login_scopes_of_query () =
  let names = function
    | Ok scopes -> Ok (List.map Github.login_scope_to_string scopes)
    | Error _ as e -> e
  in
  let result = Alcotest.(result (list string) string) in
  Alcotest.check result "absent is none" (Ok []) (names (Github.login_scopes_of_query None));
  Alcotest.check result "empty is none" (Ok []) (names (Github.login_scopes_of_query (Some "")));
  Alcotest.check
    result
    "workflow"
    (Ok [ "workflow" ])
    (names (Github.login_scopes_of_query (Some " workflow ")));
  List.iter
    (fun scope ->
      Alcotest.(check bool)
        "an offered scope reads back as itself"
        true
        (Github.login_scope_of_string (Github.login_scope_to_string scope) = Some scope))
    Github.all_login_scopes;
  match Github.login_scopes_of_query (Some "workflow,admin:org") with
  | Ok _ -> Alcotest.fail "an unoffered scope must be refused"
  | Error message ->
    Alcotest.(check bool)
      "the refusal names the scope"
      true
      (let needle = "admin:org" in
       let n = String.length needle in
       let rec go i =
         i + n <= String.length message
         && (String.equal (String.sub message i n) needle || go (i + 1))
       in
       go 0)
;;

(* The probe's stdout read on its own, over the shapes gh can hand back. Only
   the login and the scopes header leave the parser, and header text never
   becomes a login. *)
let test_probe_output_shapes () =
  let dir = Filename.temp_dir "masc-gh-probe-" "" in
  let read stdout =
    Github.auth_result_of_probe ~base_path:dir ~keeper_name:"probe"
      (Unix.WEXITED 0, stdout, "")
  in
  let scopes = Alcotest.(option (list string)) in
  let crlf = read "HTTP/2.0 200 OK\r\nX-Oauth-Scopes: repo, workflow\r\n\r\noctocat\n" in
  Alcotest.(check (option string)) "CRLF login" (Some "octocat") crlf.login;
  Alcotest.check scopes "CRLF scopes" (Some [ "repo"; "workflow" ]) crlf.scopes;
  let lf = read "HTTP/2.0 200 OK\nx-oauth-scopes: gist\n\noctocat\n" in
  Alcotest.(check (option string)) "LF login" (Some "octocat") lf.login;
  Alcotest.check scopes "header name in any case" (Some [ "gist" ]) lf.scopes;
  let empty = read "HTTP/2.0 200 OK\r\nX-Oauth-Scopes: \r\n\r\noctocat\n" in
  Alcotest.check scopes "an empty header is an empty list, not an absent one" (Some []) empty.scopes;
  let accepted =
    read "HTTP/2.0 200 OK\r\nX-Accepted-Oauth-Scopes: admin:org\r\n\r\noctocat\n"
  in
  Alcotest.check scopes "the accepted-scopes header is not the token's" None accepted.scopes;
  let headers_only = read "HTTP/2.0 200 OK\r\nX-Oauth-Scopes: repo\r\n" in
  Alcotest.(check bool) "headers with no body are not a login" false headers_only.authenticated;
  let plain = read "octocat\n" in
  Alcotest.(check (option string)) "output without headers is the login" (Some "octocat") plain.login;
  Alcotest.check scopes "and names no scopes" None plain.scopes
;;

let () =
  Alcotest.run
    "keeper GitHub identity"
    [ ( "contract"
      , [ Alcotest.test_case "environment isolation" `Quick test_pure_environment_contract
        ; Alcotest.test_case
            "login argv carries only chosen scopes"
            `Quick
            test_login_argv_carries_only_chosen_scopes
        ; Alcotest.test_case "login scopes from the query" `Quick test_login_scopes_of_query
        ; Alcotest.test_case "probe output shapes" `Quick test_probe_output_shapes
        ; Alcotest.test_case
            "fake gh login and effective identity"
            `Quick
            test_fake_gh_login_and_effective_identity
        ; Alcotest.test_case
            "fake gh set token and argv"
            `Quick
            test_fake_gh_set_token
        ; Alcotest.test_case
            "config directory keeps ancestor mode"
            `Quick
            test_config_dir_does_not_chmod_ancestor
        ; Alcotest.test_case
            "config directory is cluster scoped"
            `Quick
            test_config_dir_is_cluster_scoped
        ; Alcotest.test_case
            "config directory rejects symlink"
            `Quick
            test_config_dir_rejects_symlink
        ; Alcotest.test_case
            "credential file rejects symlink"
            `Quick
            test_config_dir_rejects_credential_symlink
        ; Alcotest.test_case
            "tool projection is nonblocking without identity"
            `Quick
            test_tool_projection_is_nonblocking_without_identity
        ; Alcotest.test_case
            "empty existing identity remains unconfigured"
            `Quick
            test_empty_existing_identity_remains_unconfigured
        ; Alcotest.test_case
            "malformed hosts yaml is rejected"
            `Quick
            test_malformed_hosts_yaml_is_rejected
        ; Alcotest.test_case
            "local snapshot cleanup does not follow replacement symlink"
            `Quick
            test_local_snapshot_cleanup_does_not_follow_replacement_symlink
        ; Alcotest.test_case
            "observation does not provision missing identity"
            `Quick
            test_observe_does_not_provision_missing_identity
        ; Alcotest.test_case
            "tool projection uses safe existing identity"
            `Quick
            test_tool_projection_uses_safe_existing_identity
        ; Alcotest.test_case
            "tool projection rejects malformed identity"
            `Quick
            test_tool_projection_rejects_malformed_identity
        ; Alcotest.test_case
            "tool projection rejects permissive identity"
            `Quick
            test_tool_projection_rejects_permissive_identity
        ; Alcotest.test_case
            "run_inherited propagates child exit status"
            `Quick
            test_run_inherited_returns_child_exit_status
        ; Alcotest.test_case
            "run_inherited times out a hung subprocess"
            `Quick
            test_run_inherited_times_out_hung_subprocess
        ; Alcotest.test_case
            "run_inherited empty argv yields 127"
            `Quick
            test_run_inherited_empty_argv_is_127
        ; Alcotest.test_case
            "stored_token reads the host scalar"
            `Quick
            test_stored_token_reads_the_host_scalar
        ; Alcotest.test_case
            "stored_token reads the users scalar"
            `Quick
            test_stored_token_reads_the_users_scalar
        ; Alcotest.test_case
            "stored_token is scoped to the named host"
            `Quick
            test_stored_token_is_scoped_to_the_named_host
        ; Alcotest.test_case
            "stored_token refuses a logged-out identity"
            `Quick
            test_stored_token_refuses_a_logged_out_identity
        ; Alcotest.test_case
            "stored_token refuses a keeper with no identity"
            `Quick
            test_stored_token_refuses_a_keeper_with_no_identity
        ; Alcotest.test_case
            "stored_token follows a relogin"
            `Quick
            test_stored_token_follows_a_relogin
        ; Alcotest.test_case
            "stored_token reads the cluster directory"
            `Quick
            test_stored_token_reads_the_cluster_directory
        ; Alcotest.test_case
            "persistent container commits under the keeper name without login"
            `Quick
            test_persistent_container_commits_under_the_keeper_name_without_login
        ; Alcotest.test_case
            "persistent container commits under the keeper name with login"
            `Quick
            test_persistent_container_commits_under_the_keeper_name_with_login
        ] )
    ]
;;

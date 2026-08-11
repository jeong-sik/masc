module Github = Keeper_github_identity
module Secret_projection = Keeper_secret_projection

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
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> run base_path)
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
case "${1-}:${2-}" in
  auth:login)
    if [ -n "${GH_TOKEN-}${GITHUB_TOKEN-}${GH_ENTERPRISE_TOKEN-}${GITHUB_ENTERPRISE_TOKEN-}" ]; then
      echo "token leaked into login" >&2
      exit 41
    fi
    printf '%s\n' "$@" > "$GH_CONFIG_DIR/login-args"
    printf '%s\n' "stored-user" > "$GH_CONFIG_DIR/stored-login"
    ;;
  api:--hostname)
    if [ -n "${GH_TOKEN-}" ]; then
      printf '%s\n' "token-user"
    elif [ -f "$GH_CONFIG_DIR/stored-login" ]; then
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
  with_temp_base @@ fun base_path ->
  let keeper_name = "github-test-keeper" in
  let fake_bin = Filename.concat base_path "fake-bin" in
  let fake_gh = Filename.concat fake_bin "gh" in
  write_file fake_gh fake_gh_script;
  Unix.chmod fake_gh 0o700;
  let secret_root = Secret_projection.secret_root ~base_path ~keeper_name in
  write_file (Filename.concat (Filename.concat secret_root "env") "GH_TOKEN") "projected-token\n";
  let previous_path = Sys.getenv "PATH" in
  Unix.putenv "PATH" (fake_bin ^ ":" ^ previous_path);
  Fun.protect
    ~finally:(fun () -> Unix.putenv "PATH" previous_path)
    (fun () ->
       Alcotest.(check int) "fake login exits successfully" 0
         (Github.run_cli_login ~base_path ~keeper_name ~hostname:"github.com");
       let keeper_config = Github.config_dir ~base_path ~keeper_name in
       let login_args = read_file (Filename.concat keeper_config "login-args") in
       Alcotest.(check bool) "web login argv reached fake gh" true
         (String.contains login_args '\n'
          && String.ends_with ~suffix:"--insecure-storage\n" login_args);
       match Github.observe ~base_path ~keeper_name ~hostname:"github.com" with
       | Error message -> Alcotest.fail message
       | Ok observation ->
         Alcotest.(check (option string)) "stored identity uses Keeper config"
           (Some "stored-user") observation.stored.login;
         Alcotest.(check (option string)) "effective identity uses projected token"
           (Some "token-user") observation.effective.login;
         Alcotest.(check (list string)) "effective token source is observable by name"
           [ "GH_TOKEN" ] observation.projected_token_env_names)
;;

let test_config_dir_does_not_chmod_ancestor () =
  with_temp_base @@ fun base_path ->
  Unix.chmod base_path 0o755;
  (match Github.ensure_config_dir ~base_path ~keeper_name:"mode-test" with
   | Error message -> Alcotest.fail message
   | Ok _ -> ());
  let mode = (Unix.stat base_path).Unix.st_perm land 0o777 in
  Alcotest.(check int) "workspace mode is unchanged" 0o755 mode
;;

let test_config_dir_rejects_symlink () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "directory-symlink-test" in
  let keeper_root =
    Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
  in
  mkdir_p keeper_root;
  let target = Filename.concat base_path "redirected-config" in
  mkdir_p target;
  Unix.symlink target (Github.config_dir ~base_path ~keeper_name);
  match Github.ensure_config_dir ~base_path ~keeper_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "symbolic-link GitHub config directory was accepted"
;;

let test_config_dir_rejects_credential_symlink () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "credential-symlink-test" in
  let config_dir =
    match Github.ensure_config_dir ~base_path ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let target = Filename.concat base_path "redirected-hosts.yml" in
  write_file target "oauth_token: do-not-touch\n";
  Unix.symlink target (Filename.concat config_dir "hosts.yml");
  match Github.ensure_config_dir ~base_path ~keeper_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "symbolic-link GitHub credential file was accepted"
;;

let test_tool_projection_is_nonblocking_without_identity () =
  with_temp_base @@ fun base_path ->
  let env =
    Github.runtime_env_for_tool
      ~base_path
      ~keeper_name:"missing-identity"
      [| "KEEP=value"; "GH_CONFIG_DIR=/host/account" |]
  in
  Alcotest.(check (option string)) "host account is not reused" (Some "/dev/null")
    (env_value "GH_CONFIG_DIR" env);
  Alcotest.(check (option string)) "unrelated env survives" (Some "value")
    (env_value "KEEP" env);
  Alcotest.(check (list string)) "docker remains runnable without a mount"
    [ "--env"; "GH_CONFIG_DIR=/dev/null" ]
    (Github.docker_args_for_tool
       ~base_path
       ~keeper_name:"missing-identity"
       ~container_masc_dir:"/tmp/masc-runtime/.masc")
;;

let test_tool_projection_uses_safe_existing_identity () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "configured-identity" in
  let host_dir =
    match Github.ensure_config_dir ~base_path ~keeper_name with
    | Error message -> Alcotest.fail message
    | Ok path -> path
  in
  let env = Github.runtime_env_for_tool ~base_path ~keeper_name [| "KEEP=value" |] in
  Alcotest.(check (option string)) "keeper account is projected" (Some host_dir)
    (env_value "GH_CONFIG_DIR" env);
  let container_masc_dir = "/tmp/masc-runtime/.masc" in
  let container_dir = Github.container_config_dir ~container_masc_dir ~keeper_name in
  Alcotest.(check (list string)) "safe identity is mounted read-only"
    [ "--env"
    ; "GH_CONFIG_DIR=" ^ container_dir
    ; "-v"
    ; host_dir ^ ":" ^ container_dir ^ ":ro"
    ]
    (Github.docker_args_for_tool ~base_path ~keeper_name ~container_masc_dir)
;;

let () =
  Alcotest.run
    "keeper GitHub identity"
    [ ( "contract"
      , [ Alcotest.test_case "environment isolation" `Quick test_pure_environment_contract
        ; Alcotest.test_case
            "fake gh login and effective identity"
            `Quick
            test_fake_gh_login_and_effective_identity
        ; Alcotest.test_case
            "config directory keeps ancestor mode"
            `Quick
            test_config_dir_does_not_chmod_ancestor
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
            "tool projection uses safe existing identity"
            `Quick
            test_tool_projection_uses_safe_existing_identity
        ] )
    ]
;;

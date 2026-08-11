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
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Unix.unlink path
;;

let with_temp_base run =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-keeper-github-%d-%.0f" (Unix.getpid ()) (Unix.gettimeofday () *. 1_000_000.))
  in
  mkdir_p base_path;
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

let () =
  Alcotest.run
    "keeper GitHub identity"
    [ ( "contract"
      , [ Alcotest.test_case "environment isolation" `Quick test_pure_environment_contract
        ; Alcotest.test_case
            "fake gh login and effective identity"
            `Quick
            test_fake_gh_login_and_effective_identity
        ] )
    ]
;;

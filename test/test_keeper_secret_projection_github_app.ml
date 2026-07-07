module Projection = Masc.Keeper_secret_projection

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0
  then true
  else if needle_len > hay_len
  then false
  else (
    let rec loop idx =
      idx + needle_len <= hay_len
      &&
      (String.equal (String.sub haystack idx needle_len) needle
       || loop (idx + 1))
    in
    loop 0)
;;

let ensure_dir path =
  if Sys.file_exists path
  then (
    if not (Sys.is_directory path)
    then Alcotest.failf "path exists but is not a directory: %s" path)
  else Unix.mkdir path 0o700
;;

let rec ensure_dir_chain path =
  let parent = Filename.dirname path in
  if not (String.equal parent path) && not (Sys.file_exists parent)
  then ensure_dir_chain parent;
  ensure_dir path
;;

let write_file path value =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc value)
;;

let with_temp_base f =
  let base_path = Filename.temp_file "masc-secret-projection-github-app-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    f base_path)
;;

let write_keeper_env ~base_path ~keeper_name name value =
  let env_dir =
    Filename.concat
      (Projection.secret_root ~base_path ~keeper_name)
      "env"
  in
  ensure_dir_chain env_dir;
  write_file (Filename.concat env_dir name) value
;;

let write_keeper_file ~base_path ~keeper_name rel value =
  let path =
    Filename.concat
      (Filename.concat (Projection.secret_root ~base_path ~keeper_name) "files")
      rel
  in
  ensure_dir_chain (Filename.dirname path);
  write_file path value
;;

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix
;;

let env_value name env =
  let prefix = name ^ "=" in
  env
  |> Array.to_list
  |> List.find_map (fun entry ->
    if starts_with ~prefix entry
    then Some (String.sub entry (String.length prefix) (String.length entry - String.length prefix))
    else None)
;;

let assert_error_contains label needle = function
  | Error err ->
    Alcotest.(check bool)
      label
      true
      (contains_substring err needle)
  | Ok _ -> Alcotest.failf "%s: expected Error" label
;;

let test_github_app_config_missing_pem_fails_closed () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "keeper-a" in
  write_keeper_env ~base_path ~keeper_name "MASC_GITHUB_APP_ID" "1\n";
  write_keeper_env ~base_path ~keeper_name "MASC_GITHUB_APP_INSTALLATION_ID" "2\n";
  write_keeper_env ~base_path ~keeper_name "GH_TOKEN" "ghp_static\n";
  Projection.local_env_for_keeper
    ~host_env:[||]
    ~base_path
    ~keeper_name
    ()
  |> assert_error_contains
       "missing PEM fails closed"
       "github_app_private_key_unavailable"
;;

let test_github_app_partial_config_fails_closed () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "keeper-b" in
  write_keeper_env ~base_path ~keeper_name "MASC_GITHUB_APP_ID" "1\n";
  write_keeper_env ~base_path ~keeper_name "GH_TOKEN" "ghp_static\n";
  Projection.local_env_for_keeper
    ~host_env:[||]
    ~base_path
    ~keeper_name
    ()
  |> assert_error_contains
       "partial config fails closed"
       "github_app_config_incomplete"
;;

let test_github_app_config_without_clock_fails_closed () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "keeper-clockless" in
  write_keeper_env ~base_path ~keeper_name "MASC_GITHUB_APP_ID" "1\n";
  write_keeper_env ~base_path ~keeper_name "MASC_GITHUB_APP_INSTALLATION_ID" "2\n";
  write_keeper_env ~base_path ~keeper_name "GH_TOKEN" "ghp_static\n";
  write_keeper_file
    ~base_path
    ~keeper_name
    "github-app/private-key.pem"
    "not-a-real-pem";
  Projection.local_env_for_keeper
    ~host_env:[||]
    ~base_path
    ~keeper_name
    ()
  |> assert_error_contains
       "clock unavailable fails closed"
       "github_app_eio_clock_unavailable"
;;

let test_no_github_app_config_keeps_static_token () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "keeper-c" in
  write_keeper_env ~base_path ~keeper_name "GH_TOKEN" "ghp_static\n";
  match
    Projection.local_env_for_keeper
      ~host_env:[||]
      ~base_path
      ~keeper_name
      ()
  with
  | Error err -> Alcotest.failf "static token projection failed: %s" err
  | Ok None -> Alcotest.fail "expected projected env"
  | Ok (Some env) ->
    Alcotest.(check (option string))
      "static token remains without app config"
      (Some "ghp_static")
      (env_value "GH_TOKEN" env)
;;

let () =
  Alcotest.run
    "keeper_secret_projection_github_app"
    [ ( "github_app_fail_closed"
      , [ Alcotest.test_case
            "configured app missing PEM fails closed"
            `Quick
            test_github_app_config_missing_pem_fails_closed
        ; Alcotest.test_case
            "partial app config fails closed"
            `Quick
            test_github_app_partial_config_fails_closed
        ; Alcotest.test_case
            "configured app without Eio clock fails closed"
            `Quick
            test_github_app_config_without_clock_fails_closed
        ] )
    ; ( "static_token_compat"
      , [ Alcotest.test_case
            "no app config keeps static token"
            `Quick
            test_no_github_app_config_keeps_static_token
        ] )
    ]
;;

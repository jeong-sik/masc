open Alcotest

let getenv_none _ = None

let getenv_base value name =
  if String.equal name "MASC_BASE_PATH" then Some value else None

let default_base_path () = "/tmp/masc-default"

let check_source label expected actual =
  check string label expected
    (Server_base_path_guard.resolution_source_label actual)

let with_env name value f =
  let prior = Sys.getenv_opt name in
  (match value with
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "")
    f

let test_implicit_default_ignores_spoofed_resolution_env () =
  with_env "MASC_BASE_PATH_RESOLUTION_SOURCE" (Some "explicit_cli") @@ fun () ->
  let resolved =
    Server_base_path_guard.resolve_startup_base_path ~getenv:getenv_none
      ~cli_base_path:None ~default_base_path ()
  in
  check_source "source" "implicit_base_path" resolved.resolution_source;
  match Server_base_path_guard.enforce resolved with
  | Error (Server_base_path_guard.Implicit_base_path _) -> ()
  | Ok () -> fail "expected implicit default to fail closed"

let test_cli_source_wins_over_env () =
  let resolved =
    Server_base_path_guard.resolve_startup_base_path
      ~getenv:(getenv_base "/tmp/from-env")
      ~cli_base_path:(Some "/tmp/from-cli")
      ~default_base_path ()
  in
  check_source "source" "explicit_cli" resolved.resolution_source;
  check string "base path" "/tmp/from-cli" resolved.normalized_base_path

let test_env_source_without_cli () =
  let resolved =
    Server_base_path_guard.resolve_startup_base_path
      ~getenv:(getenv_base "/tmp/from-env")
      ~cli_base_path:None ~default_base_path ()
  in
  check_source "source" "explicit_env" resolved.resolution_source;
  check string "base path" "/tmp/from-env" resolved.normalized_base_path

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let test_explicit_source_checkout_is_allowed () =
  with_temp_dir "masc-source-repo-" @@ fun dir ->
  Unix.mkdir (Filename.concat dir ".git") 0o755;
  let resolved =
    Server_base_path_guard.resolve_startup_base_path ~getenv:getenv_none
      ~cli_base_path:(Some dir) ~default_base_path ()
  in
  match Server_base_path_guard.enforce resolved with
  | Ok () -> ()
  | Error violation ->
      fail (Server_base_path_guard.format_violation violation)

let test_plain_workspace_allowed () =
  with_temp_dir "masc-workspace-" @@ fun dir ->
  let resolved =
    Server_base_path_guard.resolve_startup_base_path ~getenv:getenv_none
      ~cli_base_path:(Some dir) ~default_base_path ()
  in
  match Server_base_path_guard.enforce resolved with
  | Ok () -> ()
  | Error violation ->
      fail (Server_base_path_guard.format_violation violation)

let test_canonicalize_existing_freezes_symlink_target () =
  with_temp_dir "masc-canonical-path-" @@ fun dir ->
  let target = Filename.concat dir "target" in
  let alias = Filename.concat dir "alias" in
  Unix.mkdir target 0o755;
  Unix.symlink target alias;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists alias then Sys.remove alias)
    (fun () ->
       match Server_base_path_guard.canonicalize_existing alias with
       | Ok canonical ->
         check string "canonical target" (Unix.realpath target) canonical
       | Error error ->
         fail
           (Server_base_path_guard.format_canonicalization_error error))

let test_canonicalize_existing_retains_failure () =
  with_temp_dir "masc-canonical-missing-" @@ fun dir ->
  let missing = Filename.concat dir "missing" in
  match Server_base_path_guard.canonicalize_existing missing with
  | Error { base_path; cause = _; backtrace = _ } ->
    check string "failed path" missing base_path
  | Ok canonical ->
    failf "missing BasePath unexpectedly resolved to %s" canonical

let () =
  Alcotest.run "Server_base_path_guard"
    [ ( "resolution"
      , [ test_case "implicit default ignores spoofed resolution env" `Quick
            test_implicit_default_ignores_spoofed_resolution_env
        ; test_case "cli source wins over env" `Quick test_cli_source_wins_over_env
        ; test_case "env source without cli" `Quick test_env_source_without_cli
        ] )
    ; ( "guard"
      , [ test_case "explicit source checkout is allowed" `Quick
            test_explicit_source_checkout_is_allowed
        ; test_case "plain workspace allowed" `Quick test_plain_workspace_allowed
        ] )
    ; ( "canonicalization"
      , [ test_case "existing symlink target is frozen" `Quick
            test_canonicalize_existing_freezes_symlink_target
        ; test_case "canonicalization failure is retained" `Quick
            test_canonicalize_existing_retains_failure
        ] )
    ]

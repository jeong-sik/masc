open Masc_mcp

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let with_cwd path f =
  let saved = Sys.getcwd () in
  Unix.chdir path;
  Fun.protect ~finally:(fun () -> Unix.chdir saved) f
;;

let canonical_path path =
  try Unix.realpath path with
  | Unix.Unix_error _ -> path
;;

let test_divergent_cwd_is_observational_only () =
  with_temp_dir "base-path-diag"
  @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  let cwd_masc = Filename.concat cwd Common.masc_dirname in
  let effective_masc = Filename.concat effective Common.masc_dirname in
  Unix.mkdir cwd_masc 0o755;
  Unix.mkdir effective_masc 0o755;
  Unix.mkdir (Filename.concat cwd_masc "perpetual") 0o755;
  let diag =
    Server_base_path_diagnostics.detect
      ~cwd
      ~input_base_path:effective
      ~env_masc_base_path:effective
      ~effective_base_path:effective
      ~effective_masc_root:effective_masc
      ()
  in
  Alcotest.(check bool) "roots diverge" true diag.roots_diverge;
  Alcotest.(check bool) "effective .masc exists" true diag.effective_has_masc_dir;
  Alcotest.(check bool) "warning removed" false (Option.is_some diag.warning)
;;

let test_divergent_cwd_is_not_a_strict_violation () =
  with_temp_dir "base-path-strict"
  @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd Common.masc_dirname) 0o755;
  Unix.mkdir (Filename.concat effective Common.masc_dirname) 0o755;
  with_env "MASC_BASE_PATH_STRICT" (Some "false")
  @@ fun () ->
  let diag =
    Server_base_path_diagnostics.detect
      ~cwd
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective Common.masc_dirname)
      ()
  in
  Alcotest.(check bool)
    "strict_mode_requested stays false"
    false
    diag.strict_mode_requested;
  Alcotest.(check bool) "startup_rejected stays false" false diag.startup_rejected;
  Alcotest.(check bool)
    "startup_abort_eligible stays false"
    false
    diag.startup_abort_eligible;
  Alcotest.(check bool)
    "divergent cwd does not violate"
    false
    (Server_base_path_diagnostics.strict_violation diag)
;;

let test_explicit_env_resolution_remains_observational_only () =
  with_temp_dir "base-path-explicit"
  @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd Common.masc_dirname) 0o755;
  Unix.mkdir (Filename.concat effective Common.masc_dirname) 0o755;
  with_env "MASC_BASE_PATH_STRICT" (Some "true")
  @@ fun () ->
  let diag =
    Server_base_path_diagnostics.detect
      ~cwd
      ~resolution_source:"explicit_env"
      ~input_base_path:effective
      ~env_masc_base_path:effective
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective Common.masc_dirname)
      ()
  in
  Alcotest.(check bool) "warning removed" false (Option.is_some diag.warning);
  Alcotest.(check bool)
    "strict_mode_requested reflects user STRICT=true"
    true
    diag.strict_mode_requested;
  Alcotest.(check bool)
    "startup_rejected false for explicit env source"
    false
    diag.startup_rejected;
  Alcotest.(check bool)
    "startup_abort_eligible remains false"
    false
    diag.startup_abort_eligible;
  Alcotest.(check bool)
    "explicit env source stays non-violating"
    false
    (Server_base_path_diagnostics.strict_violation diag)
;;

let test_explicit_cli_resolution_source_remains_observational_only () =
  with_temp_dir "base-path-explicit-cli"
  @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd Common.masc_dirname) 0o755;
  Unix.mkdir (Filename.concat effective Common.masc_dirname) 0o755;
  with_env "MASC_BASE_PATH_STRICT" None
  @@ fun () ->
  let diag =
    Server_base_path_diagnostics.detect
      ~cwd
      ~resolution_source:"explicit_cli"
      ~input_base_path:effective
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective Common.masc_dirname)
      ()
  in
  Alcotest.(check bool)
    "strict_mode_requested false without user STRICT"
    false
    diag.strict_mode_requested;
  Alcotest.(check bool)
    "startup_rejected false for explicit cli source"
    false
    diag.startup_rejected;
  Alcotest.(check bool)
    "startup_abort_eligible false without user STRICT"
    false
    diag.startup_abort_eligible;
  Alcotest.(check bool)
    "explicit cli source stays non-violating"
    false
    (Server_base_path_diagnostics.strict_violation diag)
;;

let test_to_yojson_exposes_effective_paths () =
  let diag =
    Server_base_path_diagnostics.detect
      ~cwd:"/tmp/repo"
      ~input_base_path:"/tmp/workspace"
      ~env_masc_base_path:"/tmp/workspace"
      ~effective_base_path:"/tmp/workspace"
      ~effective_masc_root:"/tmp/workspace/.masc"
      ()
  in
  let open Yojson.Safe.Util in
  let json = Server_base_path_diagnostics.to_yojson diag in
  Alcotest.(check string)
    "effective base path"
    "/tmp/workspace"
    (json |> member "effective_base_path" |> to_string);
  Alcotest.(check string)
    "effective masc root"
    "/tmp/workspace/.masc"
    (json |> member "effective_masc_root" |> to_string);
  Alcotest.(check bool)
    "roots diverge field"
    true
    (json |> member "roots_diverge" |> to_bool);
  Alcotest.(check bool)
    "cwd legacy dirs removed"
    true
    (match json |> member "cwd_legacy_dirs" with
     | `Null -> true
     | _ -> false);
  Alcotest.(check int)
    "effective legacy dirs exposed"
    0
    (json |> member "effective_legacy_dirs" |> to_list |> List.length)
;;

let test_to_yojson_exposes_resolution_source () =
  let diag =
    Server_base_path_diagnostics.detect
      ~cwd:"/tmp/repo"
      ~resolution_source:"explicit_cli"
      ~input_base_path:"/tmp/workspace"
      ~env_masc_base_path:"/tmp/workspace"
      ~effective_base_path:"/tmp/workspace"
      ~effective_masc_root:"/tmp/workspace/.masc"
      ()
  in
  let open Yojson.Safe.Util in
  let json = Server_base_path_diagnostics.to_yojson diag in
  Alcotest.(check string)
    "resolution source"
    "explicit_cli"
    (json |> member "resolution_source" |> to_string)
;;

let test_to_yojson_exposes_gate_fields () =
  let diag =
    Server_base_path_diagnostics.detect
      ~cwd:"/tmp/repo"
      ~effective_base_path:"/tmp/workspace"
      ~effective_masc_root:"/tmp/workspace/.masc"
      ()
  in
  let open Yojson.Safe.Util in
  let json = Server_base_path_diagnostics.to_yojson diag in
  Alcotest.(check bool)
    "strict_mode_requested field"
    false
    (json |> member "strict_mode_requested" |> to_bool);
  Alcotest.(check bool)
    "startup_rejected field"
    false
    (json |> member "startup_rejected" |> to_bool);
  Alcotest.(check bool)
    "startup_abort_eligible field"
    false
    (json |> member "startup_abort_eligible" |> to_bool)
;;

let test_default_base_path_ignores_parent_base_path_override_in_tests () =
  with_temp_dir "base-path-default"
  @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path Common.masc_dirname) 0o755;
  Unix.mkdir (Filename.concat repo Common.masc_dirname) 0o755;
  with_cwd repo
  @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path)
  @@ fun () ->
  with_env "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE" None
  @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None
  @@ fun () ->
  Alcotest.(check string)
    "default base path ignores parent base path override in tests"
    (canonical_path repo)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)
;;

let test_default_base_path_preserves_base_path_override_with_opt_in () =
  with_temp_dir "base-path-default-optin"
  @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path Common.masc_dirname) 0o755;
  Unix.mkdir (Filename.concat repo Common.masc_dirname) 0o755;
  with_cwd repo
  @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path)
  @@ fun () ->
  with_env "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE" (Some "true")
  @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None
  @@ fun () ->
  Alcotest.(check string)
    "base path override preserved with opt-in"
    (canonical_path base_path)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)
;;

let test_default_base_path_ignores_base_path_override_without_local_masc () =
  with_temp_dir "base-path-default-no-local-masc"
  @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path Common.masc_dirname) 0o755;
  with_cwd repo
  @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path)
  @@ fun () ->
  with_env "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE" None
  @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None
  @@ fun () ->
  Alcotest.(check string)
    "default base path ignores base path override without local .masc"
    (canonical_path repo)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)
;;

let test_default_base_path_falls_back_to_home_when_unset () =
  with_temp_dir "base-path-default-home-fallback"
  @@ fun root ->
  let repo = Filename.concat root "repo" in
  let home = Filename.concat root "home" in
  mkdir_p repo;
  mkdir_p home;
  with_cwd repo
  @@ fun () ->
  with_env "MASC_BASE_PATH" None
  @@ fun () ->
  with_env "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE" None
  @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None
  @@ fun () ->
  with_env "HOME" (Some home)
  @@ fun () ->
  Alcotest.(check string)
    "default base path falls back to home"
    (canonical_path home)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)
;;

let () =
  Alcotest.run
    "Server_base_path_diagnostics"
    [ ( "diagnostics"
      , [ Alcotest.test_case
            "divergent cwd is observational only"
            `Quick
            test_divergent_cwd_is_observational_only
        ; Alcotest.test_case
            "divergent cwd is not strict violation"
            `Quick
            test_divergent_cwd_is_not_a_strict_violation
        ; Alcotest.test_case
            "explicit env resolution remains observational only"
            `Quick
            test_explicit_env_resolution_remains_observational_only
        ; Alcotest.test_case
            "explicit cli resolution remains observational only"
            `Quick
            test_explicit_cli_resolution_source_remains_observational_only
        ; Alcotest.test_case
            "json exposes effective paths"
            `Quick
            test_to_yojson_exposes_effective_paths
        ; Alcotest.test_case
            "json exposes resolution source"
            `Quick
            test_to_yojson_exposes_resolution_source
        ; Alcotest.test_case
            "json exposes gate fields"
            `Quick
            test_to_yojson_exposes_gate_fields
        ; Alcotest.test_case
            "default base path ignores parent base path override in tests"
            `Quick
            test_default_base_path_ignores_parent_base_path_override_in_tests
        ; Alcotest.test_case
            "default base path preserves base path override with opt-in"
            `Quick
            test_default_base_path_preserves_base_path_override_with_opt_in
        ; Alcotest.test_case
            "default base path ignores base path override without local .masc"
            `Quick
            test_default_base_path_ignores_base_path_override_without_local_masc
        ; Alcotest.test_case
            "default base path falls back to home when unset"
            `Quick
            test_default_base_path_falls_back_to_home_when_unset
        ] )
    ]
;;

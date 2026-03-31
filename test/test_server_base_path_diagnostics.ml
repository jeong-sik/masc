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

let test_detects_dual_masc_roots () =
  with_temp_dir "base-path-diag" @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd ".masc") 0o755;
  Unix.mkdir (Filename.concat effective ".masc") 0o755;
  let diag =
    Server_base_path_diagnostics.detect ~cwd
      ~input_base_path:effective
      ~env_masc_base_path:effective
      ~env_me_root:root
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective ".masc")
      ()
  in
  Alcotest.(check bool) "roots diverge" true diag.roots_diverge;
  Alcotest.(check bool) "dual roots" true diag.dual_masc_roots;
  Alcotest.(check bool) "cwd .masc exists" true diag.cwd_has_masc_dir;
  Alcotest.(check bool) "effective .masc exists" true diag.effective_has_masc_dir;
  Alcotest.(check bool) "warning present" true (Option.is_some diag.warning)

let test_strict_violation_respects_env () =
  with_temp_dir "base-path-strict" @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd ".masc") 0o755;
  Unix.mkdir (Filename.concat effective ".masc") 0o755;
  with_env "MASC_BASE_PATH_STRICT" (Some "true") @@ fun () ->
  let diag =
    Server_base_path_diagnostics.detect ~cwd
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective ".masc")
      ()
  in
  Alcotest.(check bool) "strict enabled" true diag.fail_fast_enabled;
  Alcotest.(check bool) "strict violation" true
    (Server_base_path_diagnostics.strict_violation diag)

let test_to_yojson_exposes_effective_paths () =
  let diag =
    Server_base_path_diagnostics.detect ~cwd:"/tmp/repo"
      ~input_base_path:"/tmp/workspace"
      ~env_masc_base_path:"/tmp/workspace"
      ~env_me_root:"/tmp"
      ~effective_base_path:"/tmp/workspace"
      ~effective_masc_root:"/tmp/workspace/.masc"
      ()
  in
  let open Yojson.Safe.Util in
  let json = Server_base_path_diagnostics.to_yojson diag in
  Alcotest.(check string) "effective base path" "/tmp/workspace"
    (json |> member "effective_base_path" |> to_string);
  Alcotest.(check string) "effective masc root" "/tmp/workspace/.masc"
    (json |> member "effective_masc_root" |> to_string);
  Alcotest.(check bool) "roots diverge field" true
    (json |> member "roots_diverge" |> to_bool)

let () =
  Alcotest.run "Server_base_path_diagnostics"
    [
      ( "diagnostics",
        [
          Alcotest.test_case "detects dual .masc roots" `Quick
            test_detects_dual_masc_roots;
          Alcotest.test_case "strict violation respects env" `Quick
            test_strict_violation_respects_env;
          Alcotest.test_case "json exposes effective paths" `Quick
            test_to_yojson_exposes_effective_paths;
        ] );
    ]

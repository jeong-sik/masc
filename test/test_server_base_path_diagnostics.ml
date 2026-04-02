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

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let realpath p = try Unix.realpath p with Unix.Unix_error _ -> p

let test_infer_repo_root_finds_build_ancestor () =
  with_temp_dir "infer-repo" @@ fun root ->
  let repo = Filename.concat root "my-repo" in
  let exe = Filename.concat repo "_build/default/bin/main_eio.exe" in
  mkdir_p (Filename.concat repo ".masc");
  mkdir_p (Filename.dirname exe);
  (* Create a dummy executable so realpath works *)
  let oc = open_out exe in
  close_out oc;
  let result =
    Server_mcp_transport_http_session.infer_repo_root_from_exe ~exe_path:exe ()
  in
  (* Normalize both sides: macOS /var -> /private/var symlink *)
  Alcotest.(check (option string)) "finds repo root"
    (Some (realpath repo)) result

let test_infer_repo_root_returns_none_without_masc () =
  with_temp_dir "infer-repo-no-masc" @@ fun root ->
  let repo = Filename.concat root "bare-repo" in
  let exe = Filename.concat repo "_build/default/bin/main_eio.exe" in
  mkdir_p (Filename.dirname exe);
  let oc = open_out exe in
  close_out oc;
  let result =
    Server_mcp_transport_http_session.infer_repo_root_from_exe ~exe_path:exe ()
  in
  Alcotest.(check (option string)) "returns None without .masc" None result

let test_infer_repo_root_returns_none_for_installed_binary () =
  let result =
    Server_mcp_transport_http_session.infer_repo_root_from_exe
      ~exe_path:"/usr/local/bin/masc-mcp" ()
  in
  Alcotest.(check (option string)) "returns None for installed binary" None result

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
      ( "infer_repo_root",
        [
          Alcotest.test_case "finds repo root from _build path" `Quick
            test_infer_repo_root_finds_build_ancestor;
          Alcotest.test_case "returns None without .masc dir" `Quick
            test_infer_repo_root_returns_none_without_masc;
          Alcotest.test_case "returns None for installed binary" `Quick
            test_infer_repo_root_returns_none_for_installed_binary;
        ] );
    ]

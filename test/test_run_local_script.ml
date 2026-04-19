open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let run_local_script_path () =
  Filename.concat (Filename.concat (source_root ()) "scripts") "run-local.sh"

let quote = Filename.quote

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let write_executable path content =
  write_file path content;
  Unix.chmod path 0o755

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let run_shell ?(env = []) ?(unset_env = []) ~cwd cmd =
  let unset_prefix =
    unset_env
    |> List.map (fun name -> Printf.sprintf "-u %s" (quote name))
    |> String.concat " "
  in
  let env_prefix =
    env
    |> List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v))
    |> String.concat " "
  in
  let shell_prefix =
    match (String.trim unset_prefix, String.trim env_prefix) with
    | "", "" -> ""
    | unset_prefix, "" -> Printf.sprintf "env %s" unset_prefix
    | "", env_prefix -> env_prefix
    | unset_prefix, env_prefix -> Printf.sprintf "env %s %s" unset_prefix env_prefix
  in
  let full =
    if shell_prefix = "" then
      Printf.sprintf "cd %s && %s" (quote cwd) cmd
    else
      Printf.sprintf "cd %s && %s %s" (quote cwd) shell_prefix cmd
  in
  let out = Filename.temp_file "run-local-out" ".txt" in
  let err = Filename.temp_file "run-local-err" ".txt" in
  let wrapped = Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err) in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let copy_script src dst =
  write_executable dst (read_file src)

let make_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  mkdir_p (Filename.concat config "personas");
  write_file (Filename.concat config "cascade.json") "{\"seed\":\"repo\"}";
  config

let write_fake_eio_exe exe_path =
  mkdir_p (Filename.dirname exe_path);
  let content =
    {|
#!/bin/sh
set -eu
capture="${FAKE_CAPTURE_FILE:?}"
{
  printf 'MASC_BASE_PATH=%s\n' "${MASC_BASE_PATH:-}"
  printf 'MASC_CONFIG_DIR=%s\n' "${MASC_CONFIG_DIR:-}"
  printf 'MASC_PERSONAS_DIR=%s\n' "${MASC_PERSONAS_DIR:-}"
  printf 'MASC_GRPC_ENABLED=%s\n' "${MASC_GRPC_ENABLED:-}"
  printf 'MASC_WS_ENABLED=%s\n' "${MASC_WS_ENABLED:-}"
  printf 'MASC_WEBRTC_ENABLED=%s\n' "${MASC_WEBRTC_ENABLED:-}"
  printf 'ARGS=%s\n' "$*"
} >"$capture"
exit 0
|}
  in
  write_executable exe_path content

let setup_fake_repo root =
  let repo_root = Filename.concat root "repo" in
  let scripts_dir = Filename.concat repo_root "scripts" in
  let build_dir = Filename.concat repo_root "_build/default/bin" in
  mkdir_p scripts_dir;
  ignore (make_config_root repo_root);
  copy_script (run_local_script_path ()) (Filename.concat scripts_dir "run-local.sh");
  write_fake_eio_exe (Filename.concat build_dir "main_eio.exe");
  repo_root

let test_bootstraps_local_config_and_sets_http_only_env () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_shell ~cwd:repo_root
          ~env:[ ("FAKE_CAPTURE_FILE", capture) ]
          ~unset_env:
            [ "MASC_BASE_PATH"; "MASC_CONFIG_DIR"; "MASC_PERSONAS_DIR" ]
          (Printf.sprintf "%s --target-dir %s --port 9955"
             (quote script) (quote target))
      in
      if code <> 0 then
        failf "run-local failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      let target_abs = Unix.realpath target in
      let captured = read_file capture in
      check bool "bootstrapped cascade" true
        (Sys.file_exists (Filename.concat target_abs ".masc/config/cascade.json"));
      check bool "base path set" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ target_abs));
      check bool "config dir set" true
        (contains_substring captured ("MASC_CONFIG_DIR=" ^ Filename.concat target_abs ".masc/config"));
      check bool "personas dir set" true
        (contains_substring captured ("MASC_PERSONAS_DIR=" ^ Filename.concat target_abs ".masc/config/personas"));
      check bool "grpc disabled by default" true
        (contains_substring captured "MASC_GRPC_ENABLED=0");
      check bool "ws disabled by default" true
        (contains_substring captured "MASC_WS_ENABLED=0");
      check bool "webrtc disabled by default" true
        (contains_substring captured "MASC_WEBRTC_ENABLED=0");
      check bool "port passed through" true
        (contains_substring captured "ARGS=--host=127.0.0.1 --port=9955"))

let test_print_port_is_stable_for_target_dir () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code1, stdout1, stderr1 =
        run_shell ~cwd:repo_root
          (Printf.sprintf "%s --print-port --target-dir %s"
             (quote script) (quote target))
      in
      let code2, stdout2, stderr2 =
        run_shell ~cwd:repo_root
          (Printf.sprintf "%s --print-port --target-dir %s"
             (quote script) (quote target))
      in
      if code1 <> 0 || code2 <> 0 then
        failf "print-port failed (%d/%d)\nstdout1:\n%s\nstderr1:\n%s\nstdout2:\n%s\nstderr2:\n%s"
          code1 code2 stdout1 stderr1 stdout2 stderr2;
      let port1 = int_of_string (String.trim stdout1) in
      let port2 = int_of_string (String.trim stdout2) in
      check int "stable port" port1 port2;
      check bool "port range" true (port1 >= 9100 && port1 <= 9999))

let test_build_dashboard_flag_is_opt_in () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let marker = Filename.concat dir "dashboard-build.marker" in
      let helper = Filename.concat repo_root "scripts/build-dashboard-if-needed.sh" in
      write_executable helper
        (Printf.sprintf "#!/bin/sh\nset -eu\necho invoked > %s\n" (quote marker));
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code_no_flag, stdout_no_flag, stderr_no_flag =
        run_shell ~cwd:repo_root
          ~env:[ ("FAKE_CAPTURE_FILE", capture) ]
          (Printf.sprintf "%s --target-dir %s --port 9956"
             (quote script) (quote target))
      in
      if code_no_flag <> 0 then
        failf "run-local without flag failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_no_flag stdout_no_flag stderr_no_flag;
      check bool "helper not invoked without flag" false (Sys.file_exists marker);
      let code_flag, stdout_flag, stderr_flag =
        run_shell ~cwd:repo_root
          ~env:[ ("FAKE_CAPTURE_FILE", capture) ]
          (Printf.sprintf "%s --target-dir %s --port 9957 --build-dashboard"
             (quote script) (quote target))
      in
      if code_flag <> 0 then
        failf "run-local with flag failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_flag stdout_flag stderr_flag;
      check bool "helper invoked with flag" true (Sys.file_exists marker))

let test_existing_target_config_is_not_overwritten () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      let target_config = Filename.concat target ".masc/config" in
      mkdir_p target_config;
      write_file (Filename.concat target_config "cascade.json")
        "{\"seed\":\"target\"}";
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_shell ~cwd:repo_root
          ~env:[ ("FAKE_CAPTURE_FILE", capture) ]
          (Printf.sprintf "%s --target-dir %s --port 9958"
             (quote script) (quote target))
      in
      if code <> 0 then
        failf "run-local failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      let cascade = read_file (Filename.concat target_config "cascade.json") in
      check string "target config preserved" "{\"seed\":\"target\"}" cascade)

let test_explicit_config_env_is_preserved_without_bootstrap () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      let override_root = Filename.concat dir "override-config" in
      let override_personas = Filename.concat override_root "personas" in
      mkdir_p target;
      mkdir_p override_personas;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_shell ~cwd:repo_root
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_CONFIG_DIR", override_root);
              ("MASC_PERSONAS_DIR", override_personas);
            ]
          (Printf.sprintf "%s --target-dir %s --port 9959"
             (quote script) (quote target))
      in
      if code <> 0 then
        failf "run-local with explicit config env failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      let captured = read_file capture in
      check bool "explicit config dir preserved" true
        (contains_substring captured ("MASC_CONFIG_DIR=" ^ override_root));
      check bool "explicit personas dir preserved" true
        (contains_substring captured ("MASC_PERSONAS_DIR=" ^ override_personas));
      check bool "target config not bootstrapped" false
        (Sys.file_exists (Filename.concat target ".masc/config/cascade.json")))

let test_config_dir_set_personas_dir_unset_defaults_to_config_personas () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      let override_config = Filename.concat dir "my-config" in
      mkdir_p target;
      mkdir_p override_config;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_shell ~cwd:repo_root
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_CONFIG_DIR", override_config);
            ]
          ~unset_env:[ "MASC_PERSONAS_DIR" ]
          (Printf.sprintf "%s --target-dir %s --port 9960"
             (quote script) (quote target))
      in
      if code <> 0 then
        failf "run-local with MASC_CONFIG_DIR only failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      let captured = read_file capture in
      check bool "config dir uses explicit value" true
        (contains_substring captured ("MASC_CONFIG_DIR=" ^ override_config));
      check bool "personas dir defaults to config/personas" true
        (contains_substring captured
           ("MASC_PERSONAS_DIR=" ^ Filename.concat override_config "personas")))

let test_bootstrap_only_materializes_state_without_exec () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_shell ~cwd:repo_root
          ~env:[ ("FAKE_CAPTURE_FILE", capture) ]
          ~unset_env:
            [ "MASC_BASE_PATH"; "MASC_CONFIG_DIR"; "MASC_PERSONAS_DIR" ]
          (Printf.sprintf "%s --target-dir %s --port 9961 --bootstrap-only"
             (quote script) (quote target))
      in
      if code <> 0 then
        failf "run-local bootstrap-only failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "bootstrapped cascade" true
        (Sys.file_exists (Filename.concat target ".masc/config/cascade.json"));
      check bool "fake exe not invoked" false (Sys.file_exists capture);
      check bool "bootstrap ready message" true
        (contains_substring stderr "[local-run] Bootstrap ready"))

let () =
  run "run_local_script"
    [
      ( "script",
        [
          test_case "bootstraps local config and sets http-only env" `Quick
            test_bootstraps_local_config_and_sets_http_only_env;
          test_case "print-port is stable for target dir" `Quick
            test_print_port_is_stable_for_target_dir;
          test_case "build-dashboard flag is opt-in" `Quick
            test_build_dashboard_flag_is_opt_in;
          test_case "existing target config is not overwritten" `Quick
            test_existing_target_config_is_not_overwritten;
          test_case "explicit config env is preserved without bootstrap" `Quick
            test_explicit_config_env_is_preserved_without_bootstrap;
          test_case "config_dir set personas_dir unset defaults to config/personas" `Quick
            test_config_dir_set_personas_dir_unset_defaults_to_config_personas;
          test_case "bootstrap-only materializes state without exec" `Quick
            test_bootstrap_only_materializes_state_without_exec;
        ] );
    ]

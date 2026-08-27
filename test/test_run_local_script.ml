open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let run_local_script_path () =
  Filename.concat (Filename.concat (source_root ()) "scripts") "run-local.sh"

let source_binary_identity_script_path () =
  Filename.concat
    (Filename.concat (source_root ()) "scripts")
    "source-binary-identity.sh"

let build_dashboard_if_needed_script_path () =
  Filename.concat
    (Filename.concat (source_root ()) "scripts")
    "build-dashboard-if-needed.sh"

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

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

let env_array ~unset_env overrides =
  let table = Hashtbl.create 64 in
  Unix.environment ()
  |> Array.iter (fun entry ->
         match String.index_opt entry '=' with
         | None -> ()
         | Some idx ->
             let key = String.sub entry 0 idx in
             let value =
               String.sub entry (idx + 1) (String.length entry - idx - 1)
             in
             Hashtbl.replace table key value);
  List.iter (fun key -> Hashtbl.remove table key) unset_env;
  List.iter (fun (key, value) -> Hashtbl.replace table key value) overrides;
  Hashtbl.fold
    (fun key value acc -> Printf.sprintf "%s=%s" key value :: acc)
    table []
  |> Array.of_list

let run_process ?(env = []) ?(unset_env = []) ~cwd prog argv =
  let out = Filename.temp_file "run-local-out" ".txt" in
  let err = Filename.temp_file "run-local-err" ".txt" in
  let out_fd = Unix.openfile out [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let err_fd = Unix.openfile err [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let original_cwd = Sys.getcwd () in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir original_cwd;
        Unix.close out_fd;
        Unix.close err_fd)
      (fun () ->
        Sys.chdir cwd;
        Unix.create_process_env prog argv
          (env_array ~unset_env env)
          Unix.stdin out_fd err_fd)
  in
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
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
  write_file (Filename.concat config "runtime.toml") "# repo seed\n";
  config

let write_keeper_seed repo_root =
  mkdir_p (Filename.concat repo_root "config/keepers/alpha");
  write_file
    (Filename.concat repo_root "config/keepers/alpha.toml")
    "[keeper]\nautoboot_enabled = true\ninstructions = \"Keep working autonomously.\"\n"

let write_fake_eio_exe ~commit ~fingerprint exe_path =
  mkdir_p (Filename.dirname exe_path);
  let content =
    Printf.sprintf
      {|
#!/bin/sh
set -eu
if [ "${1:-}" = "build-commit" ]; then
  printf '%%s\n' %s
  exit 0
fi
if [ "${1:-}" = "build-source-fingerprint" ]; then
  printf '%%s\n' %s
  exit 0
fi
capture="${FAKE_CAPTURE_FILE:?}"
{
  printf 'MASC_BASE_PATH=%%s\n' "${MASC_BASE_PATH:-}"
  printf 'MASC_CONFIG_DIR=%%s\n' "${MASC_CONFIG_DIR:-}"
  printf 'MASC_GRPC_ENABLED=%%s\n' "${MASC_GRPC_ENABLED:-}"
  printf 'MASC_WS_ENABLED=%%s\n' "${MASC_WS_ENABLED:-}"
  printf 'ARGS=%%s\n' "$*"
} >"$capture"
exit 0
|}
      (Filename.quote commit)
      (Filename.quote fingerprint)
  in
  write_executable exe_path content

let run_git ~cwd args =
  let argv = Array.of_list ("git" :: args) in
  let code, stdout, stderr = run_process ~cwd "git" argv in
  if code <> 0 then
    failf "git %s failed (%d)\nstdout:\n%s\nstderr:\n%s"
      (String.concat " " args) code stdout stderr;
  String.trim stdout

let git_commit_all repo_root message =
  ignore (run_git ~cwd:repo_root [ "add"; "." ]);
  ignore
    (run_git ~cwd:repo_root
       [ "-c"; "user.name=Run Local Test"; "-c";
         "user.email=run-local@example.invalid"; "commit"; "-q"; "-m";
       message ])

let source_fingerprint repo_root =
  let script = Filename.concat repo_root "scripts/source-binary-identity.sh" in
  let code, stdout, stderr =
    run_process ~cwd:repo_root script [| script; "fingerprint" |]
  in
  if code <> 0 then
    failf "source fingerprint failed (%d)\nstdout:\n%s\nstderr:\n%s"
      code stdout stderr;
  String.trim stdout

let setup_fake_repo root =
  let repo_root = Filename.concat root "repo" in
  let scripts_dir = Filename.concat repo_root "scripts" in
  let build_dir = Filename.concat repo_root "_build/default/bin" in
  mkdir_p scripts_dir;
  ignore (make_config_root repo_root);
  copy_script (run_local_script_path ()) (Filename.concat scripts_dir "run-local.sh");
  copy_script
    (source_binary_identity_script_path ())
    (Filename.concat scripts_dir "source-binary-identity.sh");
  ignore (run_git ~cwd:repo_root [ "init"; "-q" ]);
  git_commit_all repo_root "fixture";
  let commit = run_git ~cwd:repo_root [ "rev-parse"; "HEAD" ] in
  let fingerprint = source_fingerprint repo_root in
  write_fake_eio_exe ~commit ~fingerprint
    (Filename.concat build_dir "main_eio.exe");
  repo_root

let test_bootstraps_local_config_and_sets_http_only_env () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      write_keeper_seed repo_root;
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:[ ("FAKE_CAPTURE_FILE", capture) ]
          ~unset_env:
            [ "MASC_BASE_PATH"; "MASC_CONFIG_DIR" ]
          [| script; "--target-dir"; target; "--port"; "9955" |]
      in
      if code <> 0 then
        failf "run-local failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      let target_abs = Unix.realpath target in
      let captured = read_file capture in
      check bool "bootstrapped runtime.toml" true
        (Sys.file_exists (Filename.concat target_abs ".masc/config/runtime.toml"));
      check bool "did not synthesize runtime.json" false
        (Sys.file_exists (Filename.concat target_abs ".masc/config/runtime.json"));
      check bool "bootstrapped keepers excluded by default" false
        (Sys.file_exists
           (Filename.concat target_abs ".masc/config/keepers/alpha.toml"));
      check bool "base path set" true
        (String_util.contains_substring captured ("MASC_BASE_PATH=" ^ target_abs));
      check bool "config dir set" true
        (String_util.contains_substring captured ("MASC_CONFIG_DIR=" ^ Filename.concat target_abs ".masc/config"));
      check bool "grpc disabled by default" true
        (String_util.contains_substring captured "MASC_GRPC_ENABLED=0");
      check bool "ws disabled by default" true
        (String_util.contains_substring captured "MASC_WS_ENABLED=0");
      check bool "port passed through" true
        (String_util.contains_substring captured "ARGS=--host=127.0.0.1 --port=9955"))

let test_bootstrap_keepers_flag_is_opt_in () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      write_keeper_seed repo_root;
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~unset_env:
            [ "MASC_BASE_PATH"; "MASC_CONFIG_DIR" ]
          [|
            script;
            "--target-dir";
            target;
            "--port";
            "9956";
            "--bootstrap-only";
            "--bootstrap-keepers";
          |]
      in
      if code <> 0 then
        failf "run-local bootstrap-keepers failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "bootstrapped keeper copied with flag" true
        (Sys.file_exists (Filename.concat target ".masc/config/keepers/alpha.toml"));
      check bool "keepers included message" true
        (String_util.contains_substring stderr "keepers included"))

let test_print_port_is_stable_for_target_dir () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code1, stdout1, stderr1 =
        run_process ~cwd:repo_root script
          [| script; "--print-port"; "--target-dir"; target |]
      in
      let code2, stdout2, stderr2 =
        run_process ~cwd:repo_root script
          [| script; "--print-port"; "--target-dir"; target |]
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
        "#!/bin/sh\nset -eu\n: \"${DASHBOARD_MARKER:?}\"\necho invoked > \
         \"$DASHBOARD_MARKER\"\n";
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code_no_flag, stdout_no_flag, stderr_no_flag =
        run_process ~cwd:repo_root script
          ~env:[ ("FAKE_CAPTURE_FILE", capture); ("DASHBOARD_MARKER", marker) ]
          [| script; "--target-dir"; target; "--port"; "9956" |]
      in
      if code_no_flag <> 0 then
        failf "run-local without flag failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_no_flag stdout_no_flag stderr_no_flag;
      check bool "helper not invoked without flag" false (Sys.file_exists marker);
      let code_flag, stdout_flag, stderr_flag =
        run_process ~cwd:repo_root script
          ~env:[ ("FAKE_CAPTURE_FILE", capture); ("DASHBOARD_MARKER", marker) ]
          [| script; "--target-dir"; target; "--port"; "9957"; "--build-dashboard" |]
      in
      if code_flag <> 0 then
        failf "run-local with flag failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_flag stdout_flag stderr_flag;
      check bool "helper invoked with flag" true (Sys.file_exists marker))

let test_dashboard_build_helper_rebuilds_remote_startup_resource_output () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = Filename.concat dir "repo" in
      let scripts_dir = Filename.concat repo_root "scripts" in
      let dashboard_dir = Filename.concat repo_root "dashboard" in
      let output_dir = Filename.concat repo_root "assets/dashboard" in
      let fake_bin = Filename.concat dir "fake-bin" in
      let pnpm_capture = Filename.concat dir "pnpm-calls.txt" in
      mkdir_p scripts_dir;
      mkdir_p (Filename.concat dashboard_dir "src");
      mkdir_p (Filename.concat dashboard_dir "node_modules");
      mkdir_p output_dir;
      mkdir_p fake_bin;
      copy_script
        (build_dashboard_if_needed_script_path ())
        (Filename.concat scripts_dir "build-dashboard-if-needed.sh");
      write_file (Filename.concat dashboard_dir "package.json") {|{"scripts":{"build":"vite build"}}|};
      write_file (Filename.concat dashboard_dir "index.html")
        {|<!doctype html><html><head></head><body><div id="app"></div></body></html>|};
      write_file (Filename.concat dashboard_dir "src/main.ts") "export {}\n";
      write_file (Filename.concat output_dir "index.html")
        {|<!doctype html><html><head><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Noto+Sans+KR"></head><body></body></html>|};
      write_file (Filename.concat output_dir ".build-stamp") "fresh\n";
      write_executable (Filename.concat fake_bin "pnpm")
        (Printf.sprintf
           {|
#!/bin/sh
set -eu
printf '%%s\n' "$*" >> %s
case "$*" in
  "run build")
    mkdir -p ../assets/dashboard
    printf 'fresh generated dashboard\n' > ../assets/dashboard/index.html
    ;;
esac
|}
           (Filename.quote pnpm_capture));
      let script = Filename.concat scripts_dir "build-dashboard-if-needed.sh" in
      let path =
        fake_bin ^ ":" ^ Option.value ~default:"" (Sys.getenv_opt "PATH")
      in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:[ ("PATH", path) ]
          [| script |]
      in
      if code <> 0 then
        failf "dashboard build helper failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "stale generated index forced rebuild" true
        (String_util.contains_substring (read_file pnpm_capture) "run build");
      check bool "stale reason was explicit" true
        (String_util.contains_substring stderr "remote startup resources"))

let test_existing_target_config_is_not_overwritten () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      let target_config = Filename.concat target ".masc/config" in
      mkdir_p target_config;
      write_file (Filename.concat target_config "runtime.toml")
        "# preserved target runtime.toml\n";
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:[ ("FAKE_CAPTURE_FILE", capture) ]
          [| script; "--target-dir"; target; "--port"; "9958" |]
      in
      if code <> 0 then
        failf "run-local failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      let runtime = read_file (Filename.concat target_config "runtime.toml") in
      check string "target config preserved" "# preserved target runtime.toml\n" runtime)

let test_explicit_config_env_is_preserved_without_bootstrap () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      let override_root = Filename.concat dir "override-config" in
      mkdir_p target;
      mkdir_p override_root;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_CONFIG_DIR", override_root);
            ]
          [| script; "--target-dir"; target; "--port"; "9959" |]
      in
      if code <> 0 then
        failf "run-local with explicit config env failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      let captured = read_file capture in
      check bool "explicit config dir preserved" true
        (String_util.contains_substring captured ("MASC_CONFIG_DIR=" ^ override_root));
      check bool "target config not bootstrapped" false
        (Sys.file_exists (Filename.concat target ".masc/config/runtime.toml")))

let test_bootstrap_only_materializes_state_without_exec () =
  with_temp_dir "run-local-script" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:[ ("FAKE_CAPTURE_FILE", capture) ]
          ~unset_env:
            [ "MASC_BASE_PATH"; "MASC_CONFIG_DIR" ]
          [|
            script;
            "--target-dir";
            target;
            "--port";
            "9961";
            "--bootstrap-only";
          |]
      in
      if code <> 0 then
        failf "run-local bootstrap-only failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "bootstrapped runtime.toml" true
        (Sys.file_exists (Filename.concat target ".masc/config/runtime.toml"));
      check bool "did not synthesize runtime.json" false
        (Sys.file_exists (Filename.concat target ".masc/config/runtime.json"));
      check bool "fake exe not invoked" false (Sys.file_exists capture);
      check bool "bootstrap ready message" true
        (String_util.contains_substring stderr "[local-run] Bootstrap ready"))

let setup_linked_worktree_fixture ?(advance_head = true) ?(dirty_common = false) root
    ~local_binary =
  let common_root = setup_fake_repo root in
  let old_commit = run_git ~cwd:common_root [ "rev-parse"; "HEAD" ] in
  let old_fingerprint = source_fingerprint common_root in
  let worktree_root = Filename.concat root "worktree" in
  ignore
    (run_git ~cwd:common_root
       [ "worktree"; "add"; "-q"; "-b"; "feature"; worktree_root ]);
  if advance_head then begin
    mkdir_p (Filename.concat worktree_root "lib");
    write_file (Filename.concat worktree_root "lib/feature.ml") "let exact = true\n";
    git_commit_all worktree_root "feature source"
  end;
  if dirty_common then begin
    mkdir_p (Filename.concat common_root "lib");
    write_file (Filename.concat common_root "lib/dirty.ml") "let uncommitted = true\n";
    write_fake_eio_exe ~commit:old_commit
      ~fingerprint:(source_fingerprint common_root)
      (Filename.concat common_root "_build/default/bin/main_eio.exe")
  end;
  let exact_commit = run_git ~cwd:worktree_root [ "rev-parse"; "HEAD" ] in
  let exact_fingerprint = source_fingerprint worktree_root in
  let local_exe = Filename.concat worktree_root "_build/default/bin/main_eio.exe" in
  (match local_binary with
   | `Absent -> ()
   | `Stale ->
     write_fake_eio_exe ~commit:old_commit ~fingerprint:old_fingerprint local_exe);
  let built_exe = Filename.concat root "built-main-eio.exe" in
  write_fake_eio_exe ~commit:exact_commit ~fingerprint:exact_fingerprint built_exe;
  let build_marker = Filename.concat root "build.marker" in
  write_executable
    (Filename.concat worktree_root "scripts/dune-local.sh")
    {|
#!/bin/sh
set -eu
: "${FAKE_BUILD_EXE:?}"
: "${BUILD_MARKER:?}"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
mkdir -p "$repo_root/_build/default/bin"
cp "$FAKE_BUILD_EXE" "$repo_root/_build/default/bin/main_eio.exe"
printf 'built\n' >"$BUILD_MARKER"
|};
  common_root, worktree_root, exact_commit, built_exe, build_marker

let check_worktree_binary_selected_after_build ?(advance_head = true)
    ?(dirty_common = false) local_binary =
  with_temp_dir "run-local-linked" (fun dir ->
      let common_root, worktree_root, exact_commit, built_exe, build_marker =
        setup_linked_worktree_fixture ~advance_head ~dirty_common dir ~local_binary
      in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat worktree_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:worktree_root script
          ~env:[ ("FAKE_BUILD_EXE", built_exe); ("BUILD_MARKER", build_marker) ]
          [| script; "--target-dir"; target; "--bootstrap-only" |]
      in
      if code <> 0 then
        failf "linked run-local failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      let local_exe = Filename.concat worktree_root "_build/default/bin/main_eio.exe" in
      let common_exe = Filename.concat common_root "_build/default/bin/main_eio.exe" in
      check bool "build invoked" true (Sys.file_exists build_marker);
      check bool "worktree binary selected" true
        (String_util.contains_substring stderr ("Binary: " ^ local_exe));
      check bool "common binary not selected" false
        (String_util.contains_substring stderr ("Binary: " ^ common_exe));
      check bool "bootstrap reports exact embedded commit" true
        (String_util.contains_substring stderr ("Binary commit: " ^ exact_commit)))

let test_common_binary_does_not_win_when_worktree_binary_is_absent () =
  check_worktree_binary_selected_after_build `Absent

let test_common_binary_does_not_win_when_worktree_binary_is_stale () =
  check_worktree_binary_selected_after_build `Stale

let test_same_commit_common_binary_is_not_worktree_authority () =
  check_worktree_binary_selected_after_build ~advance_head:false ~dirty_common:true
    `Absent

let test_exact_local_binary_skips_build () =
  with_temp_dir "run-local-no-build" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let exact_commit = run_git ~cwd:repo_root [ "rev-parse"; "HEAD" ] in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          [| script; "--target-dir"; target; "--bootstrap-only" |]
      in
      if code <> 0 then
        failf "exact local run-local failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "build skipped" false
        (String_util.contains_substring stderr "Building local binary");
      check bool "bootstrap reports exact embedded commit" true
        (String_util.contains_substring stderr ("Binary commit: " ^ exact_commit)))

let test_dirty_source_builds_local_and_reports_dirty () =
  with_temp_dir "run-local-dirty-source" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let exact_commit = run_git ~cwd:repo_root [ "rev-parse"; "HEAD" ] in
      mkdir_p (Filename.concat repo_root "lib");
      write_file (Filename.concat repo_root "lib/dirty.ml") "let dirty = true\n";
      let exact_fingerprint = source_fingerprint repo_root in
      let built_exe = Filename.concat dir "built-main-eio.exe" in
      write_fake_eio_exe ~commit:exact_commit ~fingerprint:exact_fingerprint built_exe;
      let build_marker = Filename.concat dir "build.marker" in
      write_executable
        (Filename.concat repo_root "scripts/dune-local.sh")
        {|
#!/bin/sh
set -eu
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cp "${FAKE_BUILD_EXE:?}" "$repo_root/_build/default/bin/main_eio.exe"
printf 'built\n' >"${BUILD_MARKER:?}"
|};
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:[ ("FAKE_BUILD_EXE", built_exe); ("BUILD_MARKER", build_marker) ]
          [| script; "--target-dir"; target; "--bootstrap-only" |]
      in
      if code <> 0 then
        failf "dirty source run-local failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "dirty source rebuilt" true (Sys.file_exists build_marker);
      check bool "dirty source reported separately" true
        (String_util.contains_substring stderr "Source state: dirty"))

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
          test_case "dashboard helper rebuilds stale remote startup resources"
            `Quick
            test_dashboard_build_helper_rebuilds_remote_startup_resource_output;
          test_case "bootstrap-keepers flag is opt-in" `Quick
            test_bootstrap_keepers_flag_is_opt_in;
          test_case "existing target config is not overwritten" `Quick
            test_existing_target_config_is_not_overwritten;
          test_case "explicit config env is preserved without bootstrap" `Quick
            test_explicit_config_env_is_preserved_without_bootstrap;
          test_case "bootstrap-only materializes state without exec" `Quick
            test_bootstrap_only_materializes_state_without_exec;
          test_case "common binary loses when worktree binary is absent" `Quick
            test_common_binary_does_not_win_when_worktree_binary_is_absent;
          test_case "common binary loses when worktree binary is stale" `Quick
            test_common_binary_does_not_win_when_worktree_binary_is_stale;
          test_case "same-commit common binary is not worktree authority" `Quick
            test_same_commit_common_binary_is_not_worktree_authority;
          test_case "exact local binary skips build" `Quick
            test_exact_local_binary_skips_build;
          test_case "dirty source builds locally and reports dirty" `Quick
            test_dirty_source_builds_local_and_reports_dirty;
        ] );
    ]

open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let run_local_script_path () =
  Filename.concat (Filename.concat (source_root ()) "scripts") "run-local.sh"

let runtime_artifact_contract_script_path () =
  Filename.concat
    (Filename.concat (source_root ()) "scripts/lib")
    "runtime-artifact-contract.sh"

let run_local_executable_binding_script_path () =
  Filename.concat
    (Filename.concat (source_root ()) "scripts")
    "run-local-executable-binding.py"

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

let dashboard_test_path () =
  let ambient_path = Option.value ~default:"" (Sys.getenv_opt "PATH") in
  let directories = String.split_on_char ':' ambient_path in
  let find_directory command =
    match directories |> List.find_map (fun directory ->
           let directory = if String.equal directory "" then Sys.getcwd () else directory in
           let candidate = Filename.concat directory command in
           try
             Unix.access candidate [ Unix.X_OK ];
             Some (Unix.realpath directory)
           with
           | Unix.Unix_error _ -> None)
    with
    | Some directory -> directory
    | None -> Alcotest.failf "required test command is missing: %s" command
  in
  [ "node"; "pnpm"; "python3"; "git"; "mkdir"; "bash" ]
  |> List.map find_directory
  |> List.fold_left
       (fun unique directory ->
          if List.mem directory unique then unique else unique @ [ directory ])
       []
  |> String.concat ":"

let rec waitpid_retrying pid =
  try Unix.waitpid [] pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_retrying pid

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
  let _, status = waitpid_retrying pid in
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

let write_fake_eio_exe ~commit exe_path =
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

let setup_fake_repo root =
  let repo_root = Filename.concat root "repo" in
  let scripts_dir = Filename.concat repo_root "scripts" in
  let scripts_lib_dir = Filename.concat scripts_dir "lib" in
  let build_dir = Filename.concat repo_root "_build/default/bin" in
  mkdir_p scripts_dir;
  mkdir_p scripts_lib_dir;
  mkdir_p (Filename.concat repo_root "dashboard/node_modules/vite");
  mkdir_p (Filename.concat repo_root "assets/dashboard");
  ignore (make_config_root repo_root);
  write_file (Filename.concat repo_root "dashboard/.gitignore") "node_modules/\n";
  write_file
    (Filename.concat repo_root "dashboard/package.json")
    {|{"name":"run-local-fixture","version":"1.0.0","devDependencies":{"vite":"7.3.5"}}|};
  write_file (Filename.concat repo_root "dashboard/pnpm-lock.yaml") "lockfileVersion: '9.0'\n";
  write_file (Filename.concat repo_root "dashboard/index.html") "source dashboard\n";
  write_file
    (Filename.concat repo_root "dashboard/node_modules/vite/package.json")
    {|{"version":"7.3.5"}|};
  write_file (Filename.concat repo_root "assets/dashboard/index.html") "built dashboard\n";
  write_file (Filename.concat repo_root "assets/dashboard/.build-stamp") "fixture\n";
  copy_script (run_local_script_path ()) (Filename.concat scripts_dir "run-local.sh");
  copy_script
    (runtime_artifact_contract_script_path ())
    (Filename.concat scripts_lib_dir "runtime-artifact-contract.sh");
  copy_script
    (run_local_executable_binding_script_path ())
    (Filename.concat scripts_dir "run-local-executable-binding.py");
  write_executable
    (Filename.concat scripts_dir "dune-build-input-fingerprint.py")
    {|
#!/bin/sh
set -eu
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${DUNE_BUILD_DIR:-$repo_root/_build}"
receipt=0
for argument in "$@"; do
  if [ "$argument" = "--receipt" ]; then receipt=1; fi
done
if [ -n "${FAKE_DUNE_INPUT_CHANGED_FILE:-}" ] && [ -f "$FAKE_DUNE_INPUT_CHANGED_FILE" ]; then
  fingerprint="$(printf '%064d' 1 | tr '1' 'd')"
else
  fingerprint="$(printf '%064d' 1 | tr '1' 'b')"
fi
if [ "$receipt" = "1" ]; then
  printf 'masc.dune-build-input-receipt.v1\n%s\n%s\n' \
    "$build_dir/default/bin/main_eio.exe" "$fingerprint"
else
  printf '%s\n' "$fingerprint"
fi
|};
  write_executable
    (Filename.concat scripts_dir "dune-local.sh")
    {|
#!/bin/sh
set -eu
if [ -n "${FAKE_DUNE_BUILD_HOOK:-}" ]; then
  "$FAKE_DUNE_BUILD_HOOK"
fi
|};
  ignore (run_git ~cwd:repo_root [ "init"; "-q" ]);
  git_commit_all repo_root "fixture";
  let commit = run_git ~cwd:repo_root [ "rev-parse"; "HEAD" ] in
  write_fake_eio_exe ~commit (Filename.concat build_dir "main_eio.exe");
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
        (String_util.contains_substring captured "ARGS=--host=127.0.0.1 --port=9955");
      let private_root = Filename.concat repo_root ".git/masc-run-local-artifacts" in
      let provenance_dir = Filename.concat private_root "provenance" in
      let provenance_files = Sys.readdir provenance_dir |> Array.to_list in
      let provenance_path =
        match provenance_files with
        | [ name ] -> Filename.concat provenance_dir name
        | _ -> fail "run-local did not materialize exactly one provenance sidecar"
      in
      let provenance = Yojson.Safe.from_file provenance_path in
      let open Yojson.Safe.Util in
      check string
        "sidecar commit matches exact worktree"
        (run_git ~cwd:repo_root [ "rev-parse"; "HEAD" ])
        (provenance |> member "binary_commit" |> to_string);
      check int
        "sidecar has SHA-256 build-input fingerprint"
        64
        (provenance |> member "build_input_fingerprint" |> to_string |> String.length);
      check string
        "sidecar binds exact source root"
        (Unix.realpath repo_root)
        (provenance |> member "source_root" |> to_string);
      check bool
        "launch uses content-addressed provenance path"
        true
        (String_util.contains_substring captured
           ("--build-provenance-path=" ^ Unix.realpath provenance_path));
      check bool
        "sidecar binds executable inode"
        true
        (provenance |> member "executable_inode" |> to_int >= 0))

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
          ~env:
            [ ("FAKE_CAPTURE_FILE", capture)
            ; ("DASHBOARD_MARKER", marker)
            ; ("PATH", dashboard_test_path ())
            ]
          [| script; "--target-dir"; target; "--port"; "9957"; "--build-dashboard" |]
      in
      if code_flag <> 0 then
        failf "run-local with flag failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_flag stdout_flag stderr_flag;
      check bool "helper invoked with flag" true (Sys.file_exists marker))

let test_dashboard_build_runs_after_binary_validation () =
  with_temp_dir "run-local-dashboard-order" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let binary_marker = Filename.concat dir "binary-validated.marker" in
      let receipt_tmp = Filename.concat dir "receipt-tmp" in
      mkdir_p receipt_tmp;
      let build_hook = Filename.concat dir "binary-build-hook.sh" in
      write_executable build_hook
        "#!/bin/sh\nset -eu\n: > \"${BINARY_VALIDATED_MARKER:?}\"\n";
      let helper = Filename.concat repo_root "scripts/build-dashboard-if-needed.sh" in
      write_executable helper
        "#!/bin/sh\nset -eu\n[ -f \"${BINARY_VALIDATED_MARKER:?}\" ]\n";
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:
            [ "BINARY_VALIDATED_MARKER", binary_marker
            ; "FAKE_DUNE_BUILD_HOOK", build_hook
            ; "PATH", dashboard_test_path ()
            ; "TMPDIR", receipt_tmp
            ]
          [|
            script;
            "--target-dir";
            target;
            "--bootstrap-only";
            "--build-dashboard";
          |]
      in
      if code <> 0 then
        failf "dashboard ordering launch failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "binary validation happened before dashboard build" true
        (Sys.file_exists binary_marker);
      let leaked_build_receipts =
        Sys.readdir receipt_tmp
        |> Array.to_list
        |> List.filter (String.starts_with ~prefix:"masc-dashboard-build-receipt.")
      in
      check (list string) "bootstrap-only removes build receipt" [] leaked_build_receipts)

let test_dashboard_build_precedes_launch_binding () =
  with_temp_dir "run-local-dashboard-binding-order" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let provenance_dir =
        Filename.concat repo_root ".git/masc-run-local-artifacts/provenance"
      in
      let helper = Filename.concat repo_root "scripts/build-dashboard-if-needed.sh" in
      write_executable helper
        "#!/bin/sh\nset -eu\nset -- \"${LAUNCH_PROVENANCE_DIR:?}\"/*.json\n[ ! -f \"$1\" ]\n";
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:
            [ "LAUNCH_PROVENANCE_DIR", provenance_dir
            ; "FAKE_CAPTURE_FILE", capture
            ; "PATH", dashboard_test_path ()
            ]
          [| script; "--target-dir"; target; "--port"; "9972"; "--build-dashboard" |]
      in
      if code <> 0 then
        failf "dashboard binding order launch failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "server launched after dashboard build" true (Sys.file_exists capture);
      check bool "launch binding follows successful dashboard build" true
        (Sys.file_exists provenance_dir))

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
      (Filename.concat common_root "_build/default/bin/main_eio.exe")
  end;
  let exact_commit = run_git ~cwd:worktree_root [ "rev-parse"; "HEAD" ] in
  let local_exe = Filename.concat worktree_root "_build/default/bin/main_eio.exe" in
  (match local_binary with
   | `Absent -> ()
   | `Stale ->
     write_fake_eio_exe ~commit:old_commit local_exe);
  let built_exe = Filename.concat root "built-main-eio.exe" in
  write_fake_eio_exe ~commit:exact_commit built_exe;
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
      let local_exe =
        Filename.concat worktree_root "_build/default/bin/main_eio.exe"
        |> Unix.realpath
      in
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

let test_linked_worktree_launch_binds_worktree_dashboard_assets () =
  with_temp_dir "run-local-linked-assets" (fun dir ->
      let common_root, worktree_root, _exact_commit, built_exe, build_marker =
        setup_linked_worktree_fixture dir ~local_binary:`Absent
      in
      let write_dashboard root marker =
        let dashboard = Filename.concat root "assets/dashboard" in
        mkdir_p dashboard;
        write_file (Filename.concat dashboard "index.html") marker
      in
      write_dashboard common_root "common-dashboard";
      write_dashboard worktree_root "worktree-dashboard";
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat worktree_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:worktree_root script
          ~env:
            [ "FAKE_BUILD_EXE", built_exe
            ; "BUILD_MARKER", build_marker
            ; "FAKE_CAPTURE_FILE", capture
            ]
          [| script; "--target-dir"; target; "--port"; "9971" |]
      in
      if code <> 0 then
        failf "linked asset launch failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      let provenance_dir =
        Filename.concat common_root ".git/masc-run-local-artifacts/provenance"
      in
      let provenance_path =
        match Sys.readdir provenance_dir |> Array.to_list with
        | [ name ] -> Filename.concat provenance_dir name
        | _ -> fail "linked asset launch did not produce one provenance sidecar"
      in
      let source_root =
        Yojson.Safe.from_file provenance_path
        |> Yojson.Safe.Util.member "source_root"
        |> Yojson.Safe.Util.to_string
      in
      check string "worktree is the bound source authority"
        (Unix.realpath worktree_root) source_root;
      check string "bound dashboard sentinel is the worktree sentinel"
        "worktree-dashboard"
        (read_file (Filename.concat source_root "assets/dashboard/index.html")))

let test_exact_local_binary_is_validated_by_dune () =
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
      check bool "Dune validation is explicit" true
        (String_util.contains_substring stderr "Validating local binary with Dune");
      check bool "bootstrap reports exact embedded commit" true
        (String_util.contains_substring stderr ("Binary commit: " ^ exact_commit)))

let test_custom_dune_build_dir_is_the_launch_authority () =
  with_temp_dir "run-local-custom-build-dir" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let commit = run_git ~cwd:repo_root [ "rev-parse"; "HEAD" ] in
      let custom_build = Filename.concat dir "custom-build" in
      let custom_exe = Filename.concat custom_build "default/bin/main_eio.exe" in
      write_fake_eio_exe ~commit custom_exe;
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:[ "DUNE_BUILD_DIR", custom_build ]
          [| script; "--target-dir"; target; "--bootstrap-only" |]
      in
      if code <> 0 then
        failf "custom DUNE_BUILD_DIR failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      check bool "custom Dune target selected" true
        (String_util.contains_substring stderr ("Binary: " ^ custom_exe)))

let test_dune_dry_run_is_rejected_for_exact_launch () =
  with_temp_dir "run-local-dry-run" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, _stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:[ "MASC_DUNE_DRY_RUN", "1" ]
          [| script; "--target-dir"; target; "--bootstrap-only" |]
      in
      check bool "Dune dry-run rejected" true (code <> 0);
      check bool "dry-run rejection is explicit" true
        (String_util.contains_substring stderr
           "does not accept MASC_DUNE_DRY_RUN=1"))

let test_dune_input_change_before_exec_is_rejected () =
  with_temp_dir "run-local-dune-input-race" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let changed = Filename.concat dir "dune-input-changed" in
      let fake_bin = Filename.concat dir "bin" in
      mkdir_p fake_bin;
      write_executable
        (Filename.concat fake_bin "lsof")
        {|
#!/bin/sh
set -eu
: >"${FAKE_DUNE_INPUT_CHANGED_FILE:?}"
exit 1
|};
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let path =
        Printf.sprintf "%s:%s" fake_bin
          (Option.value ~default:"" (Sys.getenv_opt "PATH"))
      in
      let code, stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:
            [ "PATH", path
            ; "FAKE_DUNE_INPUT_CHANGED_FILE", changed
            ; "FAKE_CAPTURE_FILE", Filename.concat dir "capture"
            ]
          [| script; "--target-dir"; target |]
      in
      check bool "Dune input race rejected" true (code <> 0);
      check bool "Dune identity error is explicit" true
        (String_util.contains_substring stderr
           "Dune input or executable identity changed before local server exec");
      check bool "race marker materialized" true (Sys.file_exists changed);
      ignore stdout)

let test_mutable_build_path_replacement_blocks_exec () =
  with_temp_dir "run-local-build-path-race" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let fake_bin = Filename.concat dir "bin" in
      mkdir_p fake_bin;
      let built_exe = Filename.concat repo_root "_build/default/bin/main_eio.exe" in
      write_executable
        (Filename.concat fake_bin "lsof")
        {|
#!/bin/sh
set -eu
cat >"${BUILT_RACE_PATH:?}" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "build-commit" ]; then
  printf 'foreign-commit\n'
  exit 0
fi
exit 99
EOF
chmod 755 "$BUILT_RACE_PATH"
exit 1
|};
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let path =
        Printf.sprintf "%s:%s" fake_bin
          (Option.value ~default:"" (Sys.getenv_opt "PATH"))
      in
      let code, _stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:
            [ "PATH", path
            ; "BUILT_RACE_PATH", built_exe
            ; "FAKE_CAPTURE_FILE", capture
            ]
          [| script; "--target-dir"; target |]
      in
      check bool "build path race is rejected" true (code <> 0);
      check bool "stale binary never executed" false (Sys.file_exists capture);
      check bool "error names the changed build identity" true
        (String_util.contains_substring stderr
           "Built binary commit differs from source commit"))

let test_same_commit_swap_before_binding_is_rejected_before_rebuild () =
  with_temp_dir "run-local-binding-race" (fun dir ->
      let repo_root = setup_fake_repo dir in
      let target = Filename.concat dir "target" in
      mkdir_p target;
      let scripts_dir = Filename.concat repo_root "scripts" in
      let binding_script = Filename.concat scripts_dir "run-local-executable-binding.py" in
      let real_binding_script = binding_script ^ ".real" in
      Sys.rename binding_script real_binding_script;
      write_executable binding_script
        {|
#!/bin/sh
set -eu
if [ "${1:-}" = "--inspect-source-root" ]; then
  exec "$(dirname "$0")/run-local-executable-binding.py.real" "$@"
fi
cp "${SWAPPED_EXE_PATH:?}" "${BUILT_RACE_PATH:?}"
chmod 755 "${BUILT_RACE_PATH}"
exec "$(dirname "$0")/run-local-executable-binding.py.real" "$@"
|};
      let built_exe = Filename.concat repo_root "_build/default/bin/main_eio.exe" in
      let original_exe = Filename.concat dir "original-main-eio.exe" in
      let swapped_exe = Filename.concat dir "swapped-main-eio.exe" in
      let commit = run_git ~cwd:repo_root [ "rev-parse"; "HEAD" ] in
      write_file original_exe (read_file built_exe);
      Unix.chmod original_exe 0o755;
      write_fake_eio_exe ~commit swapped_exe;
      write_file swapped_exe (read_file swapped_exe ^ "\n# same commit, different bytes\n");
      Unix.chmod swapped_exe 0o755;
      let build_count = Filename.concat dir "build-count" in
      let rebuild_hook = Filename.concat dir "rebuild-hook.sh" in
      write_executable rebuild_hook
        {|
#!/bin/sh
set -eu
count=0
if [ -f "${BUILD_COUNT_FILE:?}" ]; then count="$(cat "$BUILD_COUNT_FILE")"; fi
count=$((count + 1))
printf '%s\n' "$count" >"$BUILD_COUNT_FILE"
if [ "$count" -ge 2 ]; then
  cp "${ORIGINAL_EXE_PATH:?}" "${BUILT_RACE_PATH:?}"
  chmod 755 "${BUILT_RACE_PATH}"
fi
|};
      let capture = Filename.concat dir "captured-env.txt" in
      let script = Filename.concat repo_root "scripts/run-local.sh" in
      let code, _stdout, stderr =
        run_process ~cwd:repo_root script
          ~env:
            [ "BUILT_RACE_PATH", built_exe
            ; "SWAPPED_EXE_PATH", swapped_exe
            ; "ORIGINAL_EXE_PATH", original_exe
            ; "BUILD_COUNT_FILE", build_count
            ; "FAKE_DUNE_BUILD_HOOK", rebuild_hook
            ; "FAKE_CAPTURE_FILE", capture
            ]
          [| script; "--target-dir"; target |]
      in
      check bool "same-commit byte swap rejected" true (code <> 0);
      check bool "swapped executable never launched" false (Sys.file_exists capture);
      check string "rebuild cannot erase the observed mismatch" "1" (String.trim (read_file build_count));
      check bool "error names initial-to-binding mismatch" true
        (String_util.contains_substring stderr
           "Materialized executable differs from the initial Dune executable"))

let test_malformed_binding_receipt_is_rejected () =
  List.iter
    (fun (corruption, label) ->
       with_temp_dir ("run-local-receipt-" ^ corruption) (fun dir ->
           let repo_root = setup_fake_repo dir in
           let target = Filename.concat dir "target" in
           mkdir_p target;
           let scripts_dir = Filename.concat repo_root "scripts" in
           let binding_script = Filename.concat scripts_dir "run-local-executable-binding.py" in
           let real_binding_script = binding_script ^ ".real" in
           Sys.rename binding_script real_binding_script;
           write_executable binding_script
             {|
#!/bin/sh
set -eu
if [ "${1:-}" = "--inspect-source-root" ]; then
  exec "$(dirname "$0")/run-local-executable-binding.py.real" "$@"
fi
receipt="$(mktemp "${TMPDIR:-/tmp}/fake-launch-receipt.XXXXXX")"
trap 'rm -f "$receipt"' EXIT
"$(dirname "$0")/run-local-executable-binding.py.real" "$@" >"$receipt"
{
  IFS= read -r schema
  IFS= read -r executable
  IFS= read -r executable_sha
  IFS= read -r provenance
  IFS= read -r provenance_sha
  IFS= read -r provenance_device
  IFS= read -r provenance_inode
} <"$receipt"
case "${FAKE_RECEIPT_CORRUPTION:?}" in
  schema) schema='masc.invalid-launch-binding.v1' ;;
  metadata) provenance_device='not-an-integer' ;;
  *) exit 2 ;;
esac
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$schema" "$executable" "$executable_sha" "$provenance" \
  "$provenance_sha" "$provenance_device" "$provenance_inode"
|};
           let capture = Filename.concat dir "captured-env.txt" in
           let script = Filename.concat repo_root "scripts/run-local.sh" in
           let code, _stdout, stderr =
             run_process ~cwd:repo_root script
               ~env:
                 [ "FAKE_RECEIPT_CORRUPTION", corruption
                 ; "FAKE_CAPTURE_FILE", capture
                 ]
               [| script; "--target-dir"; target |]
           in
           check bool (label ^ " rejected") true (code <> 0);
           check bool (label ^ " never launched") false (Sys.file_exists capture);
           check bool (label ^ " exact error") true
             (String_util.contains_substring stderr
                "Executable binding did not return an exact launch receipt")))
    [ "schema", "malformed schema"; "metadata", "malformed metadata" ]

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
          test_case "dashboard build follows binary validation" `Quick
            test_dashboard_build_runs_after_binary_validation;
          test_case "dashboard build precedes launch binding" `Quick
            test_dashboard_build_precedes_launch_binding;
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
          test_case "linked worktree launch binds its dashboard assets" `Quick
            test_linked_worktree_launch_binds_worktree_dashboard_assets;
          test_case "exact local binary is validated by Dune" `Quick
            test_exact_local_binary_is_validated_by_dune;
          test_case "custom Dune build dir is launch authority" `Quick
            test_custom_dune_build_dir_is_the_launch_authority;
          test_case "Dune dry-run is rejected for exact launch" `Quick
            test_dune_dry_run_is_rejected_for_exact_launch;
          test_case "Dune input change before exec is rejected" `Quick
            test_dune_input_change_before_exec_is_rejected;
          test_case "mutable build path replacement blocks exec" `Quick
            test_mutable_build_path_replacement_blocks_exec;
          test_case "same-commit swap before binding is rejected before rebuild" `Quick
            test_same_commit_swap_before_binding_is_rejected_before_rebuild;
          test_case "malformed binding receipt is rejected" `Quick
            test_malformed_binding_receipt_is_rejected;
        ] );
    ]

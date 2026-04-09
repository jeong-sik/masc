open Alcotest

let source_root () =
  let cwd = Sys.getcwd () in
  let cwd_script = Filename.concat cwd "scripts/ci-run-tests.sh" in
  if Sys.file_exists cwd_script then
    cwd
  else
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> cwd

let script_path () =
  Filename.concat (source_root ()) "scripts/ci-run-tests.sh"

let quote = Filename.quote

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

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

let run_shell ?(env = []) ~cwd cmd =
  let env_prefix =
    env
    |> List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v))
    |> String.concat " "
  in
  let full =
    if env_prefix = "" then
      Printf.sprintf "cd %s && %s" (quote cwd) cmd
    else
      Printf.sprintf "cd %s && %s %s" (quote cwd) env_prefix cmd
  in
  let out = Filename.temp_file "ci-run-tests-out" ".txt" in
  let err = Filename.temp_file "ci-run-tests-err" ".txt" in
  let wrapped =
    Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err)
  in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let make_fake_dune dir =
  let bin_dir = Filename.concat dir "bin" in
  Unix.mkdir bin_dir 0o755;
  let dune_path = Filename.concat bin_dir "dune" in
  write_file dune_path
    {|#!/bin/sh
set -eu
log_file="${FAKE_DUNE_LOG:?}"
printf '%s|%s|%s\n' "${1:-}" "${DUNE_BUILD_DIR:-}" "$(pwd)" >>"$log_file"
if [ "${1:-}" = "--version" ]; then
  printf '3.21.0\n'
  exit 0
fi
if [ "${1:-}" = "clean" ]; then
  exit 0
fi
if [ -z "${DUNE_BUILD_DIR:-}" ] || [ "${DUNE_BUILD_DIR}" = "_build" ]; then
  printf 'Error: RPC server not running.\n' >&2
  exit 1
fi
mkdir -p "${DUNE_BUILD_DIR}/default/test/_build/_tests"
printf 'fake ok\n' > "${DUNE_BUILD_DIR}/default/test/_build/_tests/fake.output"
printf 'Testing `fake`.\n'
exit 0
|}
  ;
  Unix.chmod dune_path 0o755;
  bin_dir

let test_rpc_retry_uses_isolated_build_dir () =
  with_temp_dir "ci-run-tests-retry" (fun dir ->
      let repo_dir = Filename.concat dir "repo" in
      Unix.mkdir repo_dir 0o755;
      let fake_log = Filename.concat dir "fake-dune.log" in
      let ci_log = Filename.concat dir "ci-run-tests.log" in
      let fake_bin = make_fake_dune dir in
      let path =
        Printf.sprintf "%s:%s" fake_bin
          (match Sys.getenv_opt "PATH" with Some p -> p | None -> "")
      in
      let env =
        [
          ("PATH", path);
          ("DUNE_BUILD_DIR", "");
          ("FAKE_DUNE_LOG", fake_log);
          ("CI_TEST_HEARTBEAT_SEC", "1");
          ("CI_TEST_TIMEOUT_SEC", "30");
          ("CI_TEST_LOG_FILE", ci_log);
          ("CI_CONTRACT_HARNESS_ENABLED", "0");
        ]
      in
      let code, stdout, stderr =
        run_shell ~cwd:dir ~env
          (Printf.sprintf "%s %s" (quote (script_path ()))
             (quote
                (Printf.sprintf "cd %s && dune test --root ." (quote repo_dir))))
      in
      if code <> 0 then
        failf "ci-run-tests failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let ci_log_contents = read_file ci_log in
      let observed_output =
        String.concat "\n" [ ci_log_contents; stdout; stderr ]
      in
      check bool "retry warning present" true
        (contains_substring observed_output
           "detected dune RPC/lock failure; retrying once with isolated build dir .ci_build");
      check bool "isolated command exports build dir" true
        (contains_substring observed_output
           "isolated_command: export DUNE_BUILD_DIR=.ci_build; unset DUNE_RPC;");
      check bool "success message present" true
        (contains_substring stdout "tests completed successfully");
      let log_lines =
        read_file fake_log
        |> String.split_on_char '\n'
        |> List.filter (fun line -> String.trim line <> "")
      in
      match log_lines with
      | [ first; second ] ->
          check string "first attempt uses default build dir and repo cwd"
            (Printf.sprintf "test||%s" repo_dir)
            first;
          check string "second attempt uses isolated build dir and repo cwd"
            (Printf.sprintf "test|.ci_build|%s" repo_dir)
            second
      | _ ->
          failf "expected exactly two dune invocations, got:\n%s"
            (String.concat "\n" log_lines))

let () =
  run "ci_run_tests_script"
    [
      ( "script",
        [
          test_case "rpc retry uses isolated build dir" `Quick
            test_rpc_retry_uses_isolated_build_dir;
        ] );
    ]

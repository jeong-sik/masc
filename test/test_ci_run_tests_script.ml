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

let write_executable path content =
  write_file path content;
  Unix.chmod path 0o755

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

let env_array overrides =
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
  List.iter (fun (key, value) -> Hashtbl.replace table key value) overrides;
  Hashtbl.fold
    (fun key value acc -> Printf.sprintf "%s=%s" key value :: acc)
    table []
  |> Array.of_list

let run_process ?(env = []) ~cwd prog argv =
  let out = Filename.temp_file "ci-run-tests-out" ".txt" in
  let err = Filename.temp_file "ci-run-tests-err" ".txt" in
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
        Unix.create_process_env prog argv (env_array env) Unix.stdin out_fd
          err_fd)
  in
  let rec wait () =
    try Unix.waitpid [] pid
    with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
  in
  let _, status = wait () in
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
  printf '  [OK]          classify_exn             2   ENOSPC.\n' >&2
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

let make_dune_test_command ~dir =
  Printf.sprintf "dune test --root %s" dir

let make_sleep_command ~dir =
  let path = Filename.concat dir "sleep-long.sh" in
  write_executable path "#!/bin/sh\nset -eu\nsleep 10\n";
  path

let run_ci ?(env = []) ~cwd command =
  let script = script_path () in
  run_process ~cwd ~env script [| script; command |]

let make_fake_dune_flaky_then_agent_sdk_artifact_failure dir =
  let bin_dir = Filename.concat dir "bin-interface" in
  Unix.mkdir bin_dir 0o755;
  let dune_path = Filename.concat bin_dir "dune" in
  write_file dune_path
    {|#!/bin/sh
set -eu
log_file="${FAKE_DUNE_LOG:?}"
printf '%s|%s|%s|%s\n' "${1:-}" "${DUNE_BUILD_DIR:-}" "${DUNE_CACHE:-}" "$(pwd)" >>"$log_file"
if [ "${1:-}" = "--version" ]; then
  printf '3.21.0\n'
  exit 0
fi
if [ "${1:-}" = "clean" ]; then
  exit 0
fi
if [ -z "${DUNE_BUILD_DIR:-}" ] || [ "${DUNE_BUILD_DIR}" = "_build" ]; then
  printf 'plain failure\n' >&2
  exit 1
fi
if [ "${DUNE_BUILD_DIR}" = ".ci_build_flaky" ] && [ "${DUNE_CACHE:-}" != "disabled" ]; then
  printf 'Error: File unavailable:\n' >&2
  printf '/tmp/opam/lib/agent_sdk/llm_provider/llm_provider.cmxa\n' >&2
  printf 'Error: Unbound module Llm_provider\n' >&2
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

let make_fake_dune_disk_full dir =
  let bin_dir = Filename.concat dir "bin-disk-full" in
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
printf 'Error: dune_trace_write(): No space left on device\n' >&2
exit 1
|}
  ;
  Unix.chmod dune_path 0o755;
  bin_dir

let make_fake_dune_deterministic_failure dir =
  let bin_dir = Filename.concat dir "bin-deterministic-failure" in
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
printf '  [FAIL]        module-init          3   keeper all complete.\n' >&2
printf 'ASSERT Keeper_metrics.all covers every constructor\n' >&2
printf '1 failure! in 0.000s. 6 tests run.\n' >&2
exit 1
|}
  ;
  Unix.chmod dune_path 0o755;
  bin_dir

let make_fake_dune_native_link_failure dir =
  let bin_dir = Filename.concat dir "bin-native-link-failure" in
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
printf 'collect2: error: ld returned 1 exit status\n' >&2
printf 'File "caml_startup", line 1:\n' >&2
printf 'Error: Error during linking (exit code 1)\n' >&2
exit 1
|}
  ;
  Unix.chmod dune_path 0o755;
  bin_dir

let make_fake_dune_github_disk_warning dir =
  let bin_dir = Filename.concat dir "bin-github-disk-warning" in
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
printf 'collect2: error: ld returned 1 exit status\n' >&2
printf 'Error: Error during linking (exit code 1)\n' >&2
printf '##[warning]You are running out of disk space. The runner will stop working when the machine runs out of disk space. Free space left: 14 MB\n' >&2
exit 1
|}
  ;
  Unix.chmod dune_path 0o755;
  bin_dir

let test_rpc_retry_uses_isolated_build_dir () =
  with_temp_dir "ci-run-tests-retry" (fun dir ->
      let cwd = Unix.realpath dir in
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
        run_ci ~cwd:dir ~env (make_dune_test_command ~dir)
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
      check bool "passing ENOSPC test name ignored" false
        (contains_substring observed_output
           "detected disk exhaustion during dune build");
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
            (Printf.sprintf "test||%s" cwd)
            first;
          check string "second attempt uses isolated build dir and repo cwd"
            (Printf.sprintf "test|.ci_build|%s" cwd)
            second
      | _ ->
          failf "expected exactly two dune invocations, got:\n%s"
            (String.concat "\n" log_lines))

let test_deterministic_failure_skips_flaky_retry () =
  with_temp_dir "ci-run-tests-deterministic-failure" (fun dir ->
      let cwd = Unix.realpath dir in
      let repo_dir = Filename.concat dir "repo" in
      Unix.mkdir repo_dir 0o755;
      let fake_log = Filename.concat dir "fake-dune.log" in
      let ci_log = Filename.concat dir "ci-run-tests.log" in
      let fake_bin = make_fake_dune_deterministic_failure dir in
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
          ("CI_TEST_ALLOW_FLAKY_RETRY", "1");
        ]
      in
      let code, stdout, stderr =
        run_ci ~cwd:dir ~env (make_dune_test_command ~dir)
      in
      check int "deterministic failure exit code" 1 code;
      let ci_log_contents = read_file ci_log in
      let observed_output =
        String.concat "\n" [ ci_log_contents; stdout; stderr ]
      in
      check bool "deterministic retry skip logged" true
        (contains_substring observed_output
           "explicit test failure detected; skipping isolated flaky retry");
      check bool "flaky retry skipped" false
        (contains_substring observed_output "flaky-test mitigation");
      let log_lines =
        read_file fake_log
        |> String.split_on_char '\n'
        |> List.filter (fun line -> String.trim line <> "")
      in
      match log_lines with
      | [ first ] ->
          check string "single attempt uses repo cwd"
            (Printf.sprintf "test||%s" cwd)
            first
      | _ ->
          failf "expected exactly one dune invocation, got:\n%s"
            (String.concat "\n" log_lines))

let test_native_link_failure_skips_flaky_retry () =
  with_temp_dir "ci-run-tests-native-link-failure" (fun dir ->
      let cwd = Unix.realpath dir in
      let repo_dir = Filename.concat dir "repo" in
      Unix.mkdir repo_dir 0o755;
      let fake_log = Filename.concat dir "fake-dune.log" in
      let ci_log = Filename.concat dir "ci-run-tests.log" in
      let fake_bin = make_fake_dune_native_link_failure dir in
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
          ("CI_TEST_ALLOW_FLAKY_RETRY", "1");
        ]
      in
      let code, stdout, stderr =
        run_ci ~cwd:dir ~env (make_dune_test_command ~dir)
      in
      check int "native link failure exit code" 1 code;
      let ci_log_contents = read_file ci_log in
      let observed_output =
        String.concat "\n" [ ci_log_contents; stdout; stderr ]
      in
      check bool "native link retry skip logged" true
        (contains_substring observed_output
           "native linker failure detected; skipping isolated flaky retry");
      check bool "flaky retry skipped" false
        (contains_substring observed_output "flaky-test mitigation");
      let log_lines =
        read_file fake_log
        |> String.split_on_char '\n'
        |> List.filter (fun line -> String.trim line <> "")
      in
      match log_lines with
      | [ first ] ->
          check string "single attempt uses repo cwd"
            (Printf.sprintf "test||%s" cwd)
            first
      | _ ->
          failf "expected exactly one dune invocation, got:\n%s"
            (String.concat "\n" log_lines))

let test_agent_sdk_artifact_failure_after_flaky_retry_disables_cache () =
  with_temp_dir "ci-run-tests-interface" (fun dir ->
      let cwd = Unix.realpath dir in
      let repo_dir = Filename.concat dir "repo" in
      Unix.mkdir repo_dir 0o755;
      let fake_log = Filename.concat dir "fake-dune.log" in
      let ci_log = Filename.concat dir "ci-run-tests.log" in
      let fake_bin = make_fake_dune_flaky_then_agent_sdk_artifact_failure dir in
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
        run_ci ~cwd:dir ~env (make_dune_test_command ~dir)
      in
      if code <> 0 then
        failf "ci-run-tests failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let ci_log_contents = read_file ci_log in
      let observed_output =
        String.concat "\n" [ ci_log_contents; stdout; stderr ]
      in
      check bool "flaky retry warning present" true
        (contains_substring observed_output
           "test failed (exit=1); retrying once with isolated build dir .ci_build_flaky");
      check bool "agent sdk artifact warning present" true
        (contains_substring observed_output
           "detected Agent_sdk/OAS artifact or interface mismatch; running dune clean and retrying once with DUNE_CACHE=disabled");
      check bool "retry command disables cache" true
        (contains_substring observed_output
           "retry_command: export DUNE_CACHE=disabled; export DUNE_BUILD_DIR=.ci_build_flaky; unset DUNE_RPC;");
      let log_lines =
        read_file fake_log
        |> String.split_on_char '\n'
        |> List.filter (fun line -> String.trim line <> "")
      in
      match log_lines with
      | [ first; second; third; fourth ] ->
          check string "first attempt uses default build dir"
            (Printf.sprintf "test|||%s" cwd)
            first;
          check string "flaky retry uses isolated build dir without cache override"
            (Printf.sprintf "test|.ci_build_flaky||%s" cwd)
            second;
          check string "clean uses isolated build dir"
            (Printf.sprintf "clean|.ci_build_flaky||%s" cwd)
            third;
          check string "clean retry disables dune cache"
            (Printf.sprintf "test|.ci_build_flaky|disabled|%s" cwd)
            fourth
      | _ ->
          failf "expected exactly four dune invocations, got:\n%s"
            (String.concat "\n" log_lines))

let test_disk_full_failure_skips_flaky_retry () =
  with_temp_dir "ci-run-tests-disk-full" (fun dir ->
      let cwd = Unix.realpath dir in
      let repo_dir = Filename.concat dir "repo" in
      Unix.mkdir repo_dir 0o755;
      let fake_log = Filename.concat dir "fake-dune.log" in
      let ci_log = Filename.concat dir "ci-run-tests.log" in
      let fake_bin = make_fake_dune_disk_full dir in
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
          ("CI_TEST_ALLOW_FLAKY_RETRY", "1");
        ]
      in
      let code, stdout, stderr =
        run_ci ~cwd:dir ~env (make_dune_test_command ~dir)
      in
      check int "disk full exit code" 1 code;
      let ci_log_contents = read_file ci_log in
      let observed_output =
        String.concat "\n" [ ci_log_contents; stdout; stderr ]
      in
      check bool "disk guidance present" true
        (contains_substring observed_output
           "detected disk exhaustion during dune build");
      check bool "disk hygiene repair present" true
        (contains_substring observed_output
           "bash scripts/disk-hygiene.sh --fix");
      check bool "flaky retry skipped" false
        (contains_substring observed_output "flaky-test mitigation");
      let log_lines =
        read_file fake_log
        |> String.split_on_char '\n'
        |> List.filter (fun line -> String.trim line <> "")
      in
      match log_lines with
      | [ first ] ->
          check string "single attempt uses repo cwd"
            (Printf.sprintf "test||%s" cwd)
            first
      | _ ->
          failf "expected exactly one dune invocation, got:\n%s"
            (String.concat "\n" log_lines))

let test_github_disk_warning_skips_flaky_retry () =
  with_temp_dir "ci-run-tests-gh-disk-warning" (fun dir ->
      let cwd = Unix.realpath dir in
      let repo_dir = Filename.concat dir "repo" in
      Unix.mkdir repo_dir 0o755;
      let fake_log = Filename.concat dir "fake-dune.log" in
      let ci_log = Filename.concat dir "ci-run-tests.log" in
      let fake_bin = make_fake_dune_github_disk_warning dir in
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
          ("CI_TEST_ALLOW_FLAKY_RETRY", "1");
        ]
      in
      let code, stdout, stderr =
        run_ci ~cwd:dir ~env (make_dune_test_command ~dir)
      in
      check int "github disk warning exit code" 1 code;
      let ci_log_contents = read_file ci_log in
      let observed_output =
        String.concat "\n" [ ci_log_contents; stdout; stderr ]
      in
      check bool "disk guidance present" true
        (contains_substring observed_output
           "detected disk exhaustion during dune build");
      check bool "github runner warning preserved" true
        (contains_substring observed_output "Free space left: 14 MB");
      check bool "flaky retry skipped" false
        (contains_substring observed_output "flaky-test mitigation");
      let log_lines =
        read_file fake_log
        |> String.split_on_char '\n'
        |> List.filter (fun line -> String.trim line <> "")
      in
      match log_lines with
      | [ first ] ->
          check string "single attempt uses repo cwd"
            (Printf.sprintf "test||%s" cwd)
            first
      | _ ->
          failf "expected exactly one dune invocation, got:\n%s"
            (String.concat "\n" log_lines))

let test_timeout_diagnostics_capture_active_process_group () =
  with_temp_dir "ci-run-tests-timeout" (fun dir ->
      let ci_log = Filename.concat dir "ci-run-tests.log" in
      let env =
        [
          ("CI_TEST_HEARTBEAT_SEC", "1");
          ("CI_TEST_TIMEOUT_SEC", "2");
          ("CI_TEST_LOG_FILE", ci_log);
          ("CI_CONTRACT_HARNESS_ENABLED", "0");
        ]
      in
      let code, stdout, stderr =
        run_ci ~cwd:dir ~env (make_sleep_command ~dir)
      in
      check int "timeout exit code" 124 code;
      let ci_log_contents = read_file ci_log in
      let observed_output =
        String.concat "\n" [ ci_log_contents; stdout; stderr ]
      in
      check bool "active command pid recorded" true
        (contains_substring observed_output "active_cmd_pid=");
      check bool "active command pgid recorded" true
        (contains_substring observed_output "active_cmd_pgid=");
      check bool "process tree snapshot recorded" true
        (contains_substring observed_output
           "active command process tree snapshot:");
      check bool "sleeping process captured" true
        (contains_substring observed_output "sleep 10"
        || contains_substring observed_output "sleep-long.sh");
      check bool "timeout error present" true
        (contains_substring observed_output
           "[ci-run] ERROR: test command timed out after 2s"))

let () =
  run "ci_run_tests_script"
    [
      ( "script",
        [
          test_case "rpc retry uses isolated build dir" `Quick
            test_rpc_retry_uses_isolated_build_dir;
          test_case "deterministic failure skips flaky retry" `Quick
            test_deterministic_failure_skips_flaky_retry;
          test_case "native link failure skips flaky retry" `Quick
            test_native_link_failure_skips_flaky_retry;
          test_case "agent sdk artifact failure after flaky retry disables cache"
            `Quick
            test_agent_sdk_artifact_failure_after_flaky_retry_disables_cache;
          test_case "disk full failure skips flaky retry" `Quick
            test_disk_full_failure_skips_flaky_retry;
          test_case "github disk warning skips flaky retry" `Quick
            test_github_disk_warning_skips_flaky_retry;
          test_case "timeout diagnostics capture active process group" `Quick
            test_timeout_diagnostics_capture_active_process_group;
        ] );
    ]

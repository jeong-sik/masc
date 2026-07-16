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

let run_ci ?(env = []) ~cwd command =
  let script = script_path () in
  run_process ~cwd ~env script [| script; command |]

let run_ci_then_signal ~cwd ~env ~ready_file command =
  let script = script_path () in
  let out = Filename.temp_file "ci-run-tests-signal-out" ".txt" in
  let err = Filename.temp_file "ci-run-tests-signal-err" ".txt" in
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
        Unix.create_process_env script [| script; command |] (env_array env)
          Unix.stdin out_fd err_fd)
  in
  let rec await_ready remaining =
    if Sys.file_exists ready_file then ()
    else if remaining = 0 then fail "observed command did not become ready"
    else (
      Unix.sleepf 0.01;
      await_ready (remaining - 1))
  in
  let waitpid_nointr () =
    let rec wait () =
      try Unix.waitpid [] pid
      with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
    in
    wait ()
  in
  let _, status =
    Fun.protect
      ~finally:(fun () ->
        try
          Unix.kill pid Sys.sigkill;
          ignore (Unix.waitpid [] pid)
        with Unix.Unix_error (Unix.ESRCH | Unix.ECHILD, _, _) -> ())
      (fun () ->
        await_ready 500;
        Unix.kill pid Sys.sigterm;
        waitpid_nointr ())
  in
  let code =
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  code, stdout, stderr

let base_env log_file =
  [
    ("CI_TEST_HEARTBEAT_SEC", "1");
    ("CI_TEST_DISK_MIN_AVAILABLE_MB", "0");
    ("CI_TEST_LOG_FILE", log_file);
    ("CI_CONTRACT_HARNESS_ENABLED", "0");
  ]

let count_lines path =
  if not (Sys.file_exists path) then
    0
  else
    read_file path |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
    |> List.length

let test_dune_command_is_observed_once_and_sanitized () =
  with_temp_dir "ci-run-tests-once" (fun dir ->
      let ci_log = Filename.concat dir "ci.log" in
      let rpc_log = Filename.concat dir "rpc.log" in
      let command =
        Printf.sprintf "printf '%%s' \"${DUNE_RPC-unset}\" > %s; # dune test"
          (Filename.quote rpc_log)
      in
      let code, stdout, stderr =
        run_ci ~cwd:dir
          ~env:(("DUNE_RPC", "stale-rpc") :: base_env ci_log)
          command
      in
      check int "success" 0 code;
      check string "DUNE_RPC removed" "unset" (read_file rpc_log);
      let observed = String.concat "\n" [ read_file ci_log; stdout; stderr ] in
      check bool "success reported" true
        (contains_substring observed "tests completed successfully"))

let test_failure_is_not_retried () =
  with_temp_dir "ci-run-tests-failure" (fun dir ->
      let ci_log = Filename.concat dir "ci.log" in
      let count_log = Filename.concat dir "count.log" in
      let command =
        Printf.sprintf "printf 'attempt\\n' >> %s; exit 7"
          (Filename.quote count_log)
      in
      let env =
        ("CI_TEST_ALLOW_FLAKY_RETRY", "1")
        :: ("CI_TEST_ALLOW_RPC_RETRY", "1")
        :: ("CI_TEST_ALLOW_CLEAN_RETRY", "1")
        :: base_env ci_log
      in
      let code, stdout, stderr = run_ci ~cwd:dir ~env command in
      check int "original exit code" 7 code;
      check int "one attempt" 1 (count_lines count_log);
      let observed = String.concat "\n" [ read_file ci_log; stdout; stderr ] in
      check bool "failure diagnostics" true
        (contains_substring observed "[ci-diag] reason=nonzero_exit_7");
      check bool "failure reported" true
        (contains_substring observed "test command failed with exit=7"))

let test_legacy_deadline_knob_does_not_terminate_command () =
  with_temp_dir "ci-run-tests-no-deadline" (fun dir ->
      let ci_log = Filename.concat dir "ci.log" in
      let done_log = Filename.concat dir "done.log" in
      let command =
        Printf.sprintf "sleep 2; printf 'done' > %s" (Filename.quote done_log)
      in
      let env = ("CI_TEST_TIMEOUT_SEC", "1") :: base_env ci_log in
      let code, _, _ = run_ci ~cwd:dir ~env command in
      check int "command completes" 0 code;
      check string "completion evidence" "done" (read_file done_log))

let test_contract_harness_runs_once () =
  with_temp_dir "ci-run-tests-contract" (fun dir ->
      let ci_log = Filename.concat dir "ci.log" in
      let count_log = Filename.concat dir "contract.log" in
      let contract_cmd =
        Printf.sprintf "printf 'contract\\n' >> %s" (Filename.quote count_log)
      in
      let env =
        ("CI_CONTRACT_HARNESS_ENABLED", "1")
        :: ("CI_CONTRACT_HARNESS_CMD", contract_cmd)
        :: List.remove_assoc "CI_CONTRACT_HARNESS_ENABLED" (base_env ci_log)
      in
      let code, stdout, stderr = run_ci ~cwd:dir ~env "true" in
      check int "success" 0 code;
      check int "one contract attempt" 1 (count_lines count_log);
      let observed = String.concat "\n" [ read_file ci_log; stdout; stderr ] in
      check bool "contract success reported" true
        (contains_substring observed "contract harness completed successfully"))

let test_signal_dumps_diagnostics_and_converges () =
  with_temp_dir "ci-run-tests-signal" (fun dir ->
      let ci_log = Filename.concat dir "ci.log" in
      let ready_file = Filename.concat dir "ready" in
      let command =
        Printf.sprintf
          "printf ready > %s; trap '' TERM INT; while :; do sleep 1; done"
          (Filename.quote ready_file)
      in
      let code, stdout, stderr =
        run_ci_then_signal ~cwd:dir ~env:(base_env ci_log) ~ready_file command
      in
      check int "TERM exit code" 143 code;
      let observed = String.concat "\n" [ read_file ci_log; stdout; stderr ] in
      check bool "signal diagnostics emitted" true
        (contains_substring observed "[ci-diag] reason=signal_TERM"))

let test_control_layers_are_absent () =
  let script = read_file (script_path ()) in
  List.iter
    (fun forbidden ->
      check bool ("absent: " ^ forbidden) false
        (contains_substring script forbidden))
    [
      "CI_TEST_TIMEOUT_SEC";
      "CI_TEST_ALLOW_FLAKY_RETRY";
      "CI_TEST_ALLOW_RPC_RETRY";
      "CI_TEST_ALLOW_CLEAN_RETRY";
      "run_with_timeout";
      "retrying once";
    ]

let () =
  run "ci_run_tests_script"
    [
      ( "script",
        [
          test_case "dune command observed once and sanitized" `Quick
            test_dune_command_is_observed_once_and_sanitized;
          test_case "failure is not retried" `Quick test_failure_is_not_retried;
          test_case "legacy deadline knob does not terminate command" `Quick
            test_legacy_deadline_knob_does_not_terminate_command;
          test_case "contract harness runs once" `Quick
            test_contract_harness_runs_once;
          test_case "signal diagnostics converge" `Quick
            test_signal_dumps_diagnostics_and_converges;
          test_case "control layers are absent" `Quick
            test_control_layers_are_absent;
        ] );
    ]

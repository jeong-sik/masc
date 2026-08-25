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
        (String_util.contains_substring observed "tests completed successfully"))

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
        (String_util.contains_substring observed "[ci-diag] reason=nonzero_exit_7");
      check bool "failure reported" true
        (String_util.contains_substring observed "test command failed with exit=7"))

let test_deadline_terminates_command_once () =
  with_temp_dir "ci-run-tests-deadline" (fun dir ->
      let ci_log = Filename.concat dir "ci.log" in
      let started_log = Filename.concat dir "started.log" in
      let done_log = Filename.concat dir "done.log" in
      let command =
        Printf.sprintf
          "printf 'started' > %s; sleep 5; printf 'done' > %s"
          (Filename.quote started_log)
          (Filename.quote done_log)
      in
      let env = ("CI_TEST_TIMEOUT_SEC", "1") :: base_env ci_log in
      let code, stdout, stderr = run_ci ~cwd:dir ~env command in
      check int "timeout exit code" 124 code;
      check string "one command started" "started" (read_file started_log);
      check bool "timed-out command did not complete" false (Sys.file_exists done_log);
      let observed = String.concat "\n" [ read_file ci_log; stdout; stderr ] in
      check bool "active process diagnostics" true
        (String_util.contains_substring observed "[ci-diag] reason=timeout_1s");
      check bool "timeout reported" true
        (String_util.contains_substring observed
           "test command timed out after 1s"))

let test_deadline_kills_reparented_term_ignoring_child () =
  with_temp_dir "ci-run-tests-descendant" (fun dir ->
      let ci_log = Filename.concat dir "ci.log" in
      let child_pid_file = Filename.concat dir "child.pid" in
      let child_heartbeat_file = Filename.concat dir "child-heartbeat.log" in
      let command =
        Printf.sprintf
          "trap 'exit 0' TERM; (trap '' TERM; while :; do printf x >> %s; sleep 1; \
           done) & child=$!; printf '%%s' \"$child\" > %s; while :; do sleep 1; done"
          (Filename.quote child_heartbeat_file)
          (Filename.quote child_pid_file)
      in
      let env = ("CI_TEST_TIMEOUT_SEC", "1") :: base_env ci_log in
      let code, _, _ = run_ci ~cwd:dir ~env command in
      check int "timeout exit code" 124 code;
      let child_pid = read_file child_pid_file |> String.trim |> int_of_string in
      let heartbeat_bytes () = (Unix.stat child_heartbeat_file).Unix.st_size in
      (* The script must kill the reparented TERM-ignoring child. run_ci can
         return before the KILL escalation lands, so poll until the child is
         actually gone (bounded) before measuring. This makes the pass case
         deterministic; a real failure to kill still trips the check below. *)
      let deadline = Unix.gettimeofday () +. 5.0 in
      let rec wait_child_dead () =
        if Unix.gettimeofday () >= deadline then ()
        else
          try
            Unix.kill child_pid 0;
            Unix.sleep 1;
            wait_child_dead ()
          with Unix.Unix_error _ -> ()
      in
      wait_child_dead ();
      let bytes_after_timeout = heartbeat_bytes () in
      Unix.sleep 2;
      let bytes_after_observation = heartbeat_bytes () in
      (try Unix.kill child_pid Sys.sigkill with Unix.Unix_error _ -> ());
      check int "TERM-ignoring descendant stops making progress"
        bytes_after_timeout
        bytes_after_observation)

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
        (String_util.contains_substring observed "contract harness completed successfully"))

let test_retry_layers_are_absent () =
  let script = read_file (script_path ()) in
  List.iter
    (fun forbidden ->
      check bool ("absent: " ^ forbidden) false
        (String_util.contains_substring script forbidden))
    [
      "CI_TEST_ALLOW_FLAKY_RETRY";
      "CI_TEST_ALLOW_RPC_RETRY";
      "CI_TEST_ALLOW_CLEAN_RETRY";
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
          test_case "deadline terminates one command" `Quick
            test_deadline_terminates_command_once;
          test_case "deadline kills a reparented TERM-ignoring child" `Quick
            test_deadline_kills_reparented_term_ignoring_child;
          test_case "contract harness runs once" `Quick
            test_contract_harness_runs_once;
          test_case "retry layers are absent" `Quick
            test_retry_layers_are_absent;
        ] );
    ]

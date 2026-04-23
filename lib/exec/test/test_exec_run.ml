(* Tick 10: foreground / background race harness.

   These tests exercise the two winning branches of
   [Exec_run.run_with_auto_bg] against a real [Eio_main.run] clock:

   1. Fast command (sleep 0.05) inside a 2 s budget -> [Completed].
      Proves the poll fiber wins and fully drains stdout before the
      budget timer fires.

   2. Slow command (sleep 5) against a 0.2 s budget -> [Promoted].
      Proves the timer fiber wins, the snapshot preserves partial
      output, and the returned [task_id] is still alive so a caller
      could keep polling.  We kill the task at the end to avoid
      leaking the long sleep.

   3. [default_budget_ms] env override round-trip.

   The tests live under [lib/exec/test] rather than [test/] so they
   only pull in [masc_exec] + [masc_process], keeping the build graph
   local.  This makes the test loop fast: no MCP server, no
   Alcotest_lwt, just Eio + Bg_task. *)

open Alcotest
open Masc_exec

let keeper = "exec_run_test"

let clean_bg_dir ~base_path =
  let bg_dir =
    Filename.concat
      (Filename.concat
         (Common.masc_dir_from_base_path ~base_path)
         (Filename.concat "keeper" keeper))
      "bg"
  in
  if Sys.file_exists bg_dir then
    let files = try Sys.readdir bg_dir with _ -> [||] in
    Array.iter (fun f ->
      try Sys.remove (Filename.concat bg_dir f) with _ -> ())
      files

let test_fast_command_completes () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let base_path = Filename.get_temp_dir_name () in
  clean_bg_dir ~base_path;
  let out =
    Exec_run.run_with_auto_bg
      ~clock
      ~poll_interval_ms:20
      ~base_path
      ~budget_ms:2000
      ~keeper
      ~argv:[ "/bin/sh"; "-c"; "printf hi" ]
      ~cwd:(Sys.getcwd ())
      ~envp:(Unix.environment ())
      ~timeout_sec:5.0
      ()
  in
  match out with
  | Exec_run.Completed r ->
    check string "stdout" "hi" r.stdout;
    (match r.status with
     | Unix.WEXITED 0 -> ()
     | _ -> fail "expected WEXITED 0")
  | Exec_run.Promoted _ -> fail "fast command should not promote"
  | Exec_run.Spawn_error _ -> fail "spawn failed"

let test_slow_command_promotes () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let base_path = Filename.get_temp_dir_name () in
  clean_bg_dir ~base_path;
  let out =
    Exec_run.run_with_auto_bg
      ~clock
      ~poll_interval_ms:20
      ~base_path
      ~budget_ms:200
      ~keeper
      ~argv:[ "/bin/sh"; "-c"; "printf early; sleep 5; printf late" ]
      ~cwd:(Sys.getcwd ())
      ~envp:(Unix.environment ())
      ~timeout_sec:30.0
      ()
  in
  match out with
  | Exec_run.Completed _ ->
    fail "slow command should have hit the budget"
  | Exec_run.Spawn_error _ -> fail "spawn failed"
  | Exec_run.Promoted p ->
    (* We saw "early" but not "late" — budget fires before sleep 5
       resolves.  Killing cleans up the long sleep. *)
    let saw_early =
      try
        let _ = Str.search_forward (Str.regexp "early") p.partial_stdout 0 in
        true
      with Not_found -> false
    in
    check bool "saw early output" true saw_early;
    let saw_late =
      try
        let _ = Str.search_forward (Str.regexp "late") p.partial_stdout 0 in
        true
      with Not_found -> false
    in
    check bool "did not see late output" false saw_late;
    let _ = Bg_task.kill p.task_id ~signal:Sys.sigterm ~grace_sec:0.2 in
    ()

let test_default_budget_env () =
  let prior = Sys.getenv_opt "MASC_BLOCKING_BUDGET_MS" in
  Unix.putenv "MASC_BLOCKING_BUDGET_MS" "777";
  let v = Exec_run.default_budget_ms () in
  check int "env honoured" 777 v;
  (match prior with
   | None -> Unix.putenv "MASC_BLOCKING_BUDGET_MS" ""
   | Some v -> Unix.putenv "MASC_BLOCKING_BUDGET_MS" v)

let () =
  run "exec_run" [
    ("race", [
      test_case "fast command completes inside budget" `Quick
        test_fast_command_completes;
      test_case "slow command promotes to bg" `Slow
        test_slow_command_promotes;
    ]);
    ("config", [
      test_case "default_budget_ms honours env" `Quick
        test_default_budget_env;
    ]);
  ]

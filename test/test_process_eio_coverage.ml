open Alcotest

module M = Masc_mcp

let contains haystack needle =
  let len_h = String.length haystack and len_n = String.length needle in
  let rec loop i =
    if i + len_n > len_h then false
    else if String.sub haystack i len_n = needle then true
    else loop (i + 1)
  in
  loop 0

let test_should_retry_unix_fallback_on_bind_error () =
  let exn = Unix.Unix_error (Unix.EADDRINUSE, "bind", "") in
  check bool "retry bind eaddrinuse" true
    (Process_eio.should_retry_unix_fallback exn)

let test_should_retry_unix_fallback_on_cancelled_bind_error () =
  let exn =
    Eio.Cancel.Cancelled (Unix.Unix_error (Unix.EADDRINUSE, "bind", ""))
  in
  check bool "retry cancelled bind eaddrinuse" true
    (Process_eio.should_retry_unix_fallback exn)

let test_run_argv_fallback_preserves_env () =
  let output =
    Process_eio.run_argv ~env:[| "PROCESS_EIO_TEST_VAR=ok" |] [ "/usr/bin/env" ]
  in
  check bool "env visible in fallback" true
    (contains output "PROCESS_EIO_TEST_VAR=ok")

let test_run_argv_with_stdin_fallback_preserves_input () =
  let output =
    Process_eio.run_argv_with_stdin ~stdin_content:"ping\n" [ "/bin/cat" ]
  in
  check string "stdin content round-trips" "ping\n" output

let test_init_exposes_complete_runtime () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  check bool "initialized" true (Process_eio.is_initialized ());
  check bool "proc_mgr available" true
    (match Process_eio.get_proc_mgr () with Ok _ -> true | Error _ -> false);
  check bool "clock available" true
    (match Process_eio.get_clock () with Ok _ -> true | Error _ -> false)

(** Verify that Eio.Cancel.Cancelled is re-raised, not swallowed *)
let test_run_argv_propagates_cancelled () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let raised = ref false in
  (try
     Eio.Cancel.sub (fun cc ->
         Eio.Cancel.cancel cc (Failure "test cancel");
         ignore (Process_eio.run_argv [ "/bin/echo"; "should-not-run" ]))
   with Eio.Cancel.Cancelled _ -> raised := true);
  check bool "Cancelled propagated from run_argv" true !raised

let test_run_argv_with_status_propagates_cancelled () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let raised = ref false in
  (try
     Eio.Cancel.sub (fun cc ->
         Eio.Cancel.cancel cc (Failure "test cancel");
         ignore (Process_eio.run_argv_with_status [ "/bin/echo"; "nope" ]))
   with Eio.Cancel.Cancelled _ -> raised := true);
  check bool "Cancelled propagated from run_argv_with_status" true !raised

let test_run_argv_with_stdin_propagates_cancelled () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let raised = ref false in
  (try
     Eio.Cancel.sub (fun cc ->
         Eio.Cancel.cancel cc (Failure "test cancel");
         ignore
           (Process_eio.run_argv_with_stdin ~stdin_content:"x"
              [ "/bin/cat" ]))
   with Eio.Cancel.Cancelled _ -> raised := true);
  check bool "Cancelled propagated from run_argv_with_stdin" true !raised

let test_run_argv_with_stdin_and_status_propagates_cancelled () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let raised = ref false in
  (try
     Eio.Cancel.sub (fun cc ->
         Eio.Cancel.cancel cc (Failure "test cancel");
         ignore
           (Process_eio.run_argv_with_stdin_and_status ~stdin_content:"x"
              [ "/bin/cat" ]))
   with Eio.Cancel.Cancelled _ -> raised := true);
  check bool "Cancelled propagated from run_argv_with_stdin_and_status" true
    !raised

let test_reset_for_testing_clears_runtime () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  check bool "initialized before reset" true (Process_eio.is_initialized ());
  Process_eio.reset_for_testing ();
  check bool "cleared after reset" false (Process_eio.is_initialized ());
  check bool "proc_mgr unavailable after reset" true
    (match Process_eio.get_proc_mgr () with Ok _ -> false | Error _ -> true)

let () =
  run "Process_eio coverage"
    [
      ( "fallback",
        [
          test_case "retry-on-bind-eaddrinuse" `Quick
            test_should_retry_unix_fallback_on_bind_error;
          test_case "retry-on-cancelled-bind-eaddrinuse" `Quick
            test_should_retry_unix_fallback_on_cancelled_bind_error;
          test_case "argv-fallback-preserves-env" `Quick
            test_run_argv_fallback_preserves_env;
          test_case "argv-with-stdin-fallback-preserves-input" `Quick
            test_run_argv_with_stdin_fallback_preserves_input;
          test_case "init-exposes-complete-runtime" `Quick
            test_init_exposes_complete_runtime;
        ] );
      ( "cancellation-propagation",
        [
          test_case "run_argv-propagates-cancelled" `Quick
            test_run_argv_propagates_cancelled;
          test_case "run_argv_with_status-propagates-cancelled" `Quick
            test_run_argv_with_status_propagates_cancelled;
          test_case "run_argv_with_stdin-propagates-cancelled" `Quick
            test_run_argv_with_stdin_propagates_cancelled;
          test_case "run_argv_with_stdin_and_status-propagates-cancelled" `Quick
            test_run_argv_with_stdin_and_status_propagates_cancelled;
          test_case "reset_for_testing-clears-runtime" `Quick
            test_reset_for_testing_clears_runtime;
        ] );
    ]

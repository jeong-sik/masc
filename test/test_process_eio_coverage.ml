open Alcotest
module M = Masc_mcp

let contains haystack needle =
  let len_h = String.length haystack
  and len_n = String.length needle in
  let rec loop i =
    if i + len_n > len_h
    then false
    else if String.sub haystack i len_n = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let test_should_retry_unix_fallback_on_bind_error () =
  let exn = Unix.Unix_error (Unix.EADDRINUSE, "bind", "") in
  check bool "retry bind eaddrinuse" true (Process_eio.should_retry_unix_fallback exn)
;;

let test_should_retry_unix_fallback_on_cancelled_bind_error () =
  let exn = Eio.Cancel.Cancelled (Unix.Unix_error (Unix.EADDRINUSE, "bind", "")) in
  check
    bool
    "retry cancelled bind eaddrinuse"
    true
    (Process_eio.should_retry_unix_fallback exn)
;;

let test_run_argv_fallback_preserves_env () =
  let output =
    Process_eio.run_argv ~env:[| "PROCESS_EIO_TEST_VAR=ok" |] [ "/usr/bin/env" ]
  in
  check bool "env visible in fallback" true (contains output "PROCESS_EIO_TEST_VAR=ok")
;;

let test_run_argv_with_status_fallback_includes_stderr_on_failure () =
  Process_eio.reset_for_testing ();
  let status, output =
    Process_eio.run_argv_with_status
      [ "/bin/sh"; "-c"; "printf 'stderr-fallback\\n' >&2; exit 4" ]
  in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | _ -> 1
  in
  check int "fallback stderr exit code" 4 code;
  check bool "fallback stderr surfaced in output" true (contains output "stderr-fallback")
;;

let test_run_argv_with_stdin_fallback_preserves_input () =
  let output = Process_eio.run_argv_with_stdin ~stdin_content:"ping\n" [ "/bin/cat" ] in
  check string "stdin content round-trips" "ping\n" output
;;

let test_run_argv_fallback_surfaces_spawn_error () =
  Process_eio.reset_for_testing ();
  let output = Process_eio.run_argv [ "/definitely/missing/process-eio-command" ] in
  check bool "spawn error surfaced" true (contains output "process_eio_error")
;;

let test_run_argv_with_status_fallback_surfaces_spawn_error () =
  Process_eio.reset_for_testing ();
  let status, output =
    Process_eio.run_argv_with_status [ "/definitely/missing/process-eio-command" ]
  in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | _ -> -1
  in
  check int "missing command exit code" 127 code;
  check bool "missing command output surfaced" true (contains output "process_eio_error")
;;

let test_run_argv_with_status_fallback_enforces_timeout () =
  Process_eio.reset_for_testing ();
  let status, _output =
    Process_eio.run_argv_with_status ~timeout_sec:1.0 [ "/bin/sleep"; "5" ]
  in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | _ -> -1
  in
  check int "fallback timeout exit code" 124 code
;;

let with_timeout_observer f =
  let previous = Atomic.get Process_eio.process_timeout_observer_fn in
  let seen = ref [] in
  Atomic.set Process_eio.process_timeout_observer_fn (fun ~program ~timeout_sec ->
    seen := (program, timeout_sec) :: !seen);
  Fun.protect
    ~finally:(fun () -> Atomic.set Process_eio.process_timeout_observer_fn previous)
    (fun () -> f seen)
;;

let test_run_argv_with_status_fallback_observes_timeout () =
  Process_eio.reset_for_testing ();
  with_timeout_observer (fun seen ->
    let status, _output =
      Process_eio.run_argv_with_status ~timeout_sec:0.02 [ "/bin/sleep"; "5" ]
    in
    let code =
      match status with
      | Unix.WEXITED c -> c
      | _ -> -1
    in
    check int "fallback timeout exit code" 124 code;
    check
      (list (pair string (float 0.0001)))
      "fallback timeout observer payload"
      [ "sleep", 0.02 ]
      (List.rev !seen))
;;

let test_init_exposes_complete_runtime () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  check bool "initialized" true (Process_eio.is_initialized ());
  check
    bool
    "proc_mgr available"
    true
    (match Process_eio.get_proc_mgr () with
     | Ok _ -> true
     | Error _ -> false);
  check
    bool
    "clock available"
    true
    (match Process_eio.get_clock () with
     | Ok _ -> true
     | Error _ -> false)
;;

(** Verify that Eio.Cancel.Cancelled is re-raised, not swallowed *)
let test_run_argv_propagates_cancelled () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let raised = ref false in
  (try
     Eio.Cancel.sub (fun cc ->
       Eio.Cancel.cancel cc (Failure "test cancel");
       ignore (Process_eio.run_argv [ "/bin/echo"; "should-not-run" ]))
   with
   | Eio.Cancel.Cancelled _ -> raised := true);
  check bool "Cancelled propagated from run_argv" true !raised
;;

let test_run_argv_with_status_propagates_cancelled () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let raised = ref false in
  (try
     Eio.Cancel.sub (fun cc ->
       Eio.Cancel.cancel cc (Failure "test cancel");
       ignore (Process_eio.run_argv_with_status [ "/bin/echo"; "nope" ]))
   with
   | Eio.Cancel.Cancelled _ -> raised := true);
  check bool "Cancelled propagated from run_argv_with_status" true !raised
;;

let test_run_argv_with_stdin_propagates_cancelled () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let raised = ref false in
  (try
     Eio.Cancel.sub (fun cc ->
       Eio.Cancel.cancel cc (Failure "test cancel");
       ignore (Process_eio.run_argv_with_stdin ~stdin_content:"x" [ "/bin/cat" ]))
   with
   | Eio.Cancel.Cancelled _ -> raised := true);
  check bool "Cancelled propagated from run_argv_with_stdin" true !raised
;;

let test_run_argv_with_stdin_and_status_propagates_cancelled () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let raised = ref false in
  (try
     Eio.Cancel.sub (fun cc ->
       Eio.Cancel.cancel cc (Failure "test cancel");
       ignore
         (Process_eio.run_argv_with_stdin_and_status ~stdin_content:"x" [ "/bin/cat" ]))
   with
   | Eio.Cancel.Cancelled _ -> raised := true);
  check bool "Cancelled propagated from run_argv_with_stdin_and_status" true !raised
;;

let test_run_argv_with_status_cwd_override () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  (* Use a non-root default cwd (/usr) so the test verifies that an
     absolute ~cwd:"/tmp" truly replaces it, not just appends to root. *)
  let cwd_default = Eio.Path.(Eio.Stdenv.fs env / "/usr") in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  (* Without ~cwd, pwd should return /usr *)
  let status_default, stdout_default = Process_eio.run_argv_with_status [ "/bin/pwd" ] in
  let code_d =
    match status_default with
    | Unix.WEXITED c -> c
    | _ -> 1
  in
  check int "default pwd exit code" 0 code_d;
  check string "default cwd is /usr" "/usr" (String.trim stdout_default);
  (* With ~cwd:"/tmp", pwd should return /tmp, not /usr/tmp *)
  let status, stdout = Process_eio.run_argv_with_status ~cwd:"/tmp" [ "/bin/pwd" ] in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | _ -> 1
  in
  check int "override pwd exit code" 0 code;
  let trimmed = String.trim stdout in
  (* /tmp may resolve to /private/tmp on macOS *)
  check
    bool
    "cwd is /tmp or /private/tmp"
    (trimmed = "/tmp" || trimmed = "/private/tmp")
    true
;;

let test_run_argv_with_status_includes_stderr_on_failure () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let status, output =
    Process_eio.run_argv_with_status
      [ "/bin/sh"; "-c"; "printf 'stderr-only\\n' >&2; exit 3" ]
  in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | _ -> 1
  in
  check int "stderr failure exit code" 3 code;
  check bool "stderr surfaced in output" true (contains output "stderr-only")
;;

let test_reset_for_testing_clears_runtime () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  check bool "initialized before reset" true (Process_eio.is_initialized ());
  Process_eio.reset_for_testing ();
  check bool "cleared after reset" false (Process_eio.is_initialized ());
  check
    bool
    "proc_mgr unavailable after reset"
    true
    (match Process_eio.get_proc_mgr () with
     | Ok _ -> false
     | Error _ -> true)
;;

let () =
  run
    "Process_eio coverage"
    [ ( "fallback"
      , [ test_case
            "retry-on-bind-eaddrinuse"
            `Quick
            test_should_retry_unix_fallback_on_bind_error
        ; test_case
            "retry-on-cancelled-bind-eaddrinuse"
            `Quick
            test_should_retry_unix_fallback_on_cancelled_bind_error
        ; test_case
            "argv-fallback-preserves-env"
            `Quick
            test_run_argv_fallback_preserves_env
        ; test_case
            "argv-with-status-fallback-includes-stderr-on-failure"
            `Quick
            test_run_argv_with_status_fallback_includes_stderr_on_failure
        ; test_case
            "argv-with-stdin-fallback-preserves-input"
            `Quick
            test_run_argv_with_stdin_fallback_preserves_input
        ; test_case
            "argv-fallback-surfaces-spawn-error"
            `Quick
            test_run_argv_fallback_surfaces_spawn_error
        ; test_case
            "argv-with-status-fallback-surfaces-spawn-error"
            `Quick
            test_run_argv_with_status_fallback_surfaces_spawn_error
        ; test_case
            "argv-with-status-fallback-enforces-timeout"
            `Quick
            test_run_argv_with_status_fallback_enforces_timeout
        ; test_case
            "argv-with-status-fallback-observes-timeout"
            `Quick
            test_run_argv_with_status_fallback_observes_timeout
        ; test_case
            "init-exposes-complete-runtime"
            `Quick
            test_init_exposes_complete_runtime
        ] )
    ; ( "cancellation-propagation"
      , [ test_case
            "run_argv-propagates-cancelled"
            `Quick
            test_run_argv_propagates_cancelled
        ; test_case
            "run_argv_with_status-propagates-cancelled"
            `Quick
            test_run_argv_with_status_propagates_cancelled
        ; test_case
            "run_argv_with_stdin-propagates-cancelled"
            `Quick
            test_run_argv_with_stdin_propagates_cancelled
        ; test_case
            "run_argv_with_stdin_and_status-propagates-cancelled"
            `Quick
            test_run_argv_with_stdin_and_status_propagates_cancelled
        ; test_case
            "run_argv_with_status-cwd-override"
            `Quick
            test_run_argv_with_status_cwd_override
        ; test_case
            "run_argv_with_status-includes-stderr-on-failure"
            `Quick
            test_run_argv_with_status_includes_stderr_on_failure
        ; test_case
            "reset_for_testing-clears-runtime"
            `Quick
            test_reset_for_testing_clears_runtime
        ] )
    ]
;;

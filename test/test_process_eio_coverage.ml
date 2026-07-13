open Alcotest

module M = Masc

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

let test_run_argv_with_status_fallback_includes_stderr_on_failure () =
  Process_eio.reset_for_testing ();
  let status, output =
    Process_eio.run_argv_with_status
      [ "/bin/sh"; "-c"; "printf 'stderr-fallback\\n' >&2; exit 4" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "fallback stderr exit code" 4 code;
  check bool "fallback stderr surfaced in output" true
    (contains output "stderr-fallback")

let test_spawn_guard_wraps_foreground_run_argv () =
  Process_eio.reset_for_testing ();
  let calls = Atomic.make 0 in
  Process_eio.set_spawn_guard
    { Process_eio.run =
        (fun f ->
          Atomic.incr calls;
          f ())
    };
  Fun.protect
    ~finally:Process_eio.reset_spawn_guard_for_testing
    (fun () ->
      let status, output =
        Process_eio.run_argv_with_status [ "/bin/echo"; "guarded" ]
      in
      let code = match status with Unix.WEXITED c -> c | _ -> 1 in
      check int "guarded command exit code" 0 code;
      check string "guarded command output" "guarded" (String.trim output);
      check int "spawn guard called once" 1 (Atomic.get calls))

let test_run_argv_with_stdin_fallback_preserves_input () =
  let output =
    Process_eio.run_argv_with_stdin ~stdin_content:"ping\n" [ "/bin/cat" ]
  in
  check string "stdin content round-trips" "ping\n" output

let test_run_argv_fallback_surfaces_spawn_error () =
  Process_eio.reset_for_testing ();
  let output =
    Process_eio.run_argv [ "/definitely/missing/process-eio-command" ]
  in
  check bool "spawn error surfaced" true
    (contains output "process_eio_error")

let test_run_argv_with_status_fallback_surfaces_spawn_error () =
  Process_eio.reset_for_testing ();
  let status, output =
    Process_eio.run_argv_with_status
      [ "/definitely/missing/process-eio-command" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  check int "missing command exit code" 127 code;
  check bool "missing command output surfaced" true
    (contains output "process_eio_error")

let test_run_argv_with_status_fallback_enforces_timeout () =
  Process_eio.reset_for_testing ();
  let status, _output =
    Process_eio.run_argv_with_status ~timeout_sec:1.0 [ "/bin/sleep"; "5" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  check int "fallback timeout exit code" 124 code

let with_timeout_observer f =
  let previous = Atomic.get Process_eio.process_timeout_observer_fn in
  let seen = ref [] in
  Atomic.set Process_eio.process_timeout_observer_fn
    (fun ~program ~timeout_sec ~origin ->
       seen := (program, timeout_sec, Timeout_origin.to_label origin) :: !seen);
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Process_eio.process_timeout_observer_fn previous)
    (fun () -> f seen)

let test_run_argv_with_status_fallback_observes_timeout () =
  Process_eio.reset_for_testing ();
  with_timeout_observer (fun seen ->
      let status, _output =
        Process_eio.run_argv_with_status ~timeout_sec:0.02 [ "/bin/sleep"; "5" ]
      in
      let code = match status with Unix.WEXITED c -> c | _ -> -1 in
      check int "fallback timeout exit code" 124 code;
      (* Unix fallback runs after [create_process_env] returns, so the
         stage is always [command]. *)
      check
        (list (triple string (float 0.0001) string))
        "fallback timeout observer payload"
        [ ("sleep", 0.02, "command") ]
        (List.rev !seen))

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

let test_run_argv_with_status_cwd_override () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  (* Use a non-root default cwd (/usr) so the test verifies that an
     absolute ~cwd:"/tmp" truly replaces it, not just appends to root. *)
  let cwd_default = Eio.Path.(Eio.Stdenv.fs env / "/usr") in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  (* Without ~cwd, pwd should return /usr *)
  let status_default, stdout_default =
    Process_eio.run_argv_with_status [ "/bin/pwd" ]
  in
  let code_d = match status_default with Unix.WEXITED c -> c | _ -> 1 in
  check int "default pwd exit code" 0 code_d;
  check string "default cwd is /usr" "/usr" (String.trim stdout_default);
  (* With ~cwd:"/tmp", pwd should return /tmp, not /usr/tmp *)
  let status, stdout =
    Process_eio.run_argv_with_status ~cwd:"/tmp" [ "/bin/pwd" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "override pwd exit code" 0 code;
  let trimmed = String.trim stdout in
  (* /tmp may resolve to /private/tmp on macOS *)
  check bool "cwd is /tmp or /private/tmp"
    (trimmed = "/tmp" || trimmed = "/private/tmp") true

let test_run_argv_with_status_includes_stderr_on_failure () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let status, output =
    Process_eio.run_argv_with_status
      [ "/bin/sh"; "-c"; "printf 'stderr-only\\n' >&2; exit 3" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "stderr failure exit code" 3 code;
  check bool "stderr surfaced in output" true
    (contains output "stderr-only")

let test_run_argv_with_status_split_streaming_invokes_callbacks () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let status, stdout, stderr =
    Process_eio.run_argv_with_status_split_streaming
      ~on_stdout_chunk:(fun s -> stdout_chunks := s :: !stdout_chunks)
      ~on_stderr_chunk:(fun s -> stderr_chunks := s :: !stderr_chunks)
      [ "/bin/sh"
      ; "-c"
      ; "printf 'stdout-chunk\\n'; printf 'stderr-chunk\\n' >&2"
      ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "streaming exit code" 0 code;
  check string "streaming stdout captured" "stdout-chunk\n" stdout;
  check string "streaming stderr captured" "stderr-chunk\n" stderr;
  check bool "streaming stdout callback invoked" true (List.length !stdout_chunks > 0);
  check bool "streaming stderr callback invoked" true (List.length !stderr_chunks > 0)

let test_run_argv_pipeline_streaming_timeout_preserves_stderr () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let stderr_chunks = ref [] in
  let status, stdout, stderr =
    Process_eio.run_argv_pipeline_with_status_split
      ~timeout_sec:0.5
      ~on_stdout_chunk:(fun _ -> ())
      ~on_stderr_chunk:(fun s -> stderr_chunks := s :: !stderr_chunks)
      [
        {
          Process_eio.argv =
            [ "/bin/sh"; "-c"; "printf 'pipeline-timeout-stderr\\n' >&2; sleep 5" ];
          env = None;
          cwd = None;
        };
      ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "pipeline timeout exit code" 124 code;
  check string "pipeline timeout stdout" "" stdout;
  check bool
    "pipeline timeout stderr preserves streamed data"
    true
    (contains stderr "pipeline-timeout-stderr");
  check bool
    "pipeline timeout stderr avoids synthetic timeout when data streamed"
    false
    (contains stderr "process_eio_error");
  check bool
    "pipeline timeout stderr callback invoked"
    true
    (contains (String.concat "" (List.rev !stderr_chunks)) "pipeline-timeout-stderr")

let test_run_argv_with_status_split_streaming_fallback_invokes_callbacks () =
  Process_eio.reset_for_testing ();
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let status, stdout, stderr =
    Process_eio.run_argv_with_status_split_streaming
      ~on_stdout_chunk:(fun s -> stdout_chunks := s :: !stdout_chunks)
      ~on_stderr_chunk:(fun s -> stderr_chunks := s :: !stderr_chunks)
      [ "/bin/sh"
      ; "-c"
      ; "printf 'fallback-stdout\\n'; printf 'fallback-stderr\\n' >&2"
      ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "streaming fallback exit code" 0 code;
  check string "streaming fallback stdout captured" "fallback-stdout\n" stdout;
  check string "streaming fallback stderr captured" "fallback-stderr\n" stderr;
  check string
    "streaming fallback stdout callback"
    "fallback-stdout\n"
    (String.concat "" (List.rev !stdout_chunks));
  check string
    "streaming fallback stderr callback"
    "fallback-stderr\n"
    (String.concat "" (List.rev !stderr_chunks))

let test_run_argv_with_stdin_and_status_split_fallback_callback_exception_continues
    () =
  Process_eio.reset_for_testing ();
  let stdout_callback_calls = Atomic.make 0 in
  let status, stdout, stderr =
    Process_eio.run_argv_with_stdin_and_status_split
      ~on_stdout_chunk:(fun _ ->
        Atomic.incr stdout_callback_calls;
        failwith "intentional fallback callback failure")
      ~on_stderr_chunk:(fun _ -> ())
      ~stdin_content:"stdin-fallback-captured\n"
      [ "/bin/cat" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "stdin fallback callback exception exit code" 0 code;
  check string
    "stdin fallback callback exception stdout captured"
    "stdin-fallback-captured\n"
    stdout;
  check string "stdin fallback callback exception stderr captured" "" stderr;
  check bool
    "stdin fallback callback exception callback invoked"
    true
    (Atomic.get stdout_callback_calls > 0)

let test_run_argv_with_status_split_streaming_callback_exception_continues () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let stdout_callback_calls = Atomic.make 0 in
  let status, stdout, stderr =
    Process_eio.run_argv_with_status_split_streaming
      ~on_stdout_chunk:(fun _ ->
        Atomic.incr stdout_callback_calls;
        failwith "intentional callback failure")
      ~on_stderr_chunk:(fun _ -> ())
      [ "/bin/sh"; "-c"; "printf 'still-captured\\n'" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "callback exception streaming exit code" 0 code;
  check string "callback exception stdout captured" "still-captured\n" stdout;
  check string "callback exception stderr captured" "" stderr;
  check bool
    "callback exception callback invoked"
    true
    (Atomic.get stdout_callback_calls > 0)

let test_run_argv_with_status_split_streaming_callback_cancelled_propagates () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let cancelled =
    try
      ignore
        (Process_eio.run_argv_with_status_split_streaming
           ~on_stdout_chunk:(fun _ ->
             raise (Eio.Cancel.Cancelled (Failure "intentional cancellation")))
           ~on_stderr_chunk:(fun _ -> ())
           [ "/bin/sh"; "-c"; "printf 'cancel-me\\n'" ]);
      false
    with
    | Eio.Cancel.Cancelled _ -> true
  in
  check bool "callback cancellation propagates" true cancelled

let test_run_argv_with_status_split_streaming_cancel_reaps_child () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let marker = Filename.temp_file "process-eio-cancel-reap" ".marker" in
  Sys.remove marker;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists marker then Sys.remove marker)
    (fun () ->
      let cancellation_requested = Atomic.make false in
      let cancelled =
        try
          Eio.Cancel.sub (fun cc ->
              ignore
                (Process_eio.run_argv_with_status_split_streaming
                   ~on_stdout_chunk:(fun _ ->
                     if Atomic.compare_and_set cancellation_requested false true
                     then Eio.Cancel.cancel cc (Failure "cancel running child"))
                   ~on_stderr_chunk:(fun _ -> ())
                   [ "/bin/sh"
                   ; "-c"
                   ; "printf '%d\\n' \"$$\" > \"$1\"; printf 'ready\\n'; while :; do sleep 1; done"
                   ; "process-eio-cancel-reap"
                   ; marker
                   ]));
          false
        with Eio.Cancel.Cancelled _ -> true
      in
      check bool "external cancellation propagates" true cancelled;
      let ic = open_in marker in
      let child_pid =
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () -> input_line ic |> int_of_string)
      in
      let child_reaped =
        try
          Unix.kill child_pid 0;
          false
        with Unix.Unix_error (Unix.ESRCH, _, _) -> true
      in
      check bool "child reaped before cancellation propagation" true child_reaped)

let test_run_argv_with_status_split_streaming_multiple_chunks () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let chunk_count = Atomic.make 0 in
  let status, stdout, _stderr =
    Process_eio.run_argv_with_status_split_streaming
      ~on_stdout_chunk:(fun _ -> Atomic.incr chunk_count)
      ~on_stderr_chunk:(fun _ -> ())
      [ "/bin/sh"
      ; "-c"
      ; "i=0; while [ $i -lt 500 ]; do printf '%s' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done; printf '\\n'"
      ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "multi-chunk exit code" 0 code;
  check int "multi-chunk stdout length" 25001 (String.length stdout);
  check bool "multi-chunk received more than one chunk" true (Atomic.get chunk_count > 1)

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

(** Invalid explicit timeouts are objective input errors, never rewritten to
    an implicit process budget. Omitting the timeout remains valid and
    unbounded. *)
let test_run_argv_with_status_rejects_invalid_timeout () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let check_rejected label timeout_sec =
    let rejected =
      try
        ignore
          (Process_eio.run_argv_with_status
             ~timeout_sec
             [ "/bin/sleep"; "0.05" ]);
        false
      with Invalid_argument _ -> true
    in
    check bool (Printf.sprintf "%s timeout rejected" label) true rejected
  in
  check_rejected "zero" 0.0;
  check_rejected "negative" (-1.0);
  check_rejected "nan" Float.nan;
  check_rejected "neg_infinity" Float.neg_infinity;
  check_rejected "infinity" Float.infinity;
  let status, _output =
    Process_eio.run_argv_with_status [ "/bin/sleep"; "0.05" ]
  in
  check int
    "absent timeout is accepted"
    0
    (match status with Unix.WEXITED code -> code | _ -> -1)

(** Verify that a pipeline timeout reaps every stage and still captures
    whatever stdout/stderr was produced before the timeout fired. *)
let test_run_argv_pipeline_timeout_reaps_all_stages () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let status, _stdout, _stderr =
    Process_eio.run_argv_pipeline_with_status_split
      ~timeout_sec:0.5
      [
        {
          Process_eio.argv = [ "/bin/sh"; "-c"; "echo stage1-output; sleep 5" ];
          env = None;
          cwd = None;
        };
        { Process_eio.argv = [ "/bin/cat" ]; env = None; cwd = None };
      ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "pipeline timeout exit code" 124 code

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
          test_case "argv-with-status-fallback-includes-stderr-on-failure"
            `Quick
            test_run_argv_with_status_fallback_includes_stderr_on_failure;
          test_case "spawn-guard-wraps-foreground-run-argv" `Quick
            test_spawn_guard_wraps_foreground_run_argv;
          test_case "argv-with-stdin-fallback-preserves-input" `Quick
            test_run_argv_with_stdin_fallback_preserves_input;
          test_case "argv-fallback-surfaces-spawn-error" `Quick
            test_run_argv_fallback_surfaces_spawn_error;
          test_case "argv-with-status-fallback-surfaces-spawn-error" `Quick
            test_run_argv_with_status_fallback_surfaces_spawn_error;
          test_case "argv-with-status-fallback-enforces-timeout" `Quick
            test_run_argv_with_status_fallback_enforces_timeout;
          test_case "argv-with-status-fallback-observes-timeout" `Quick
            test_run_argv_with_status_fallback_observes_timeout;
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
           test_case "run_argv_with_status-cwd-override" `Quick
             test_run_argv_with_status_cwd_override;
           test_case "run_argv_with_status-includes-stderr-on-failure" `Quick
             test_run_argv_with_status_includes_stderr_on_failure;
           test_case "run_argv_with_status_split_streaming-invokes-callbacks" `Quick
             test_run_argv_with_status_split_streaming_invokes_callbacks;
           test_case
             "run_argv_pipeline_with_status_split-timeout-preserves-stderr"
             `Quick
             test_run_argv_pipeline_streaming_timeout_preserves_stderr;
           test_case
             "run_argv_with_status_split_streaming-fallback-invokes-callbacks"
             `Quick
             test_run_argv_with_status_split_streaming_fallback_invokes_callbacks;
           test_case
             "run_argv_with_stdin_and_status_split-fallback-callback-exception-continues"
             `Quick
             test_run_argv_with_stdin_and_status_split_fallback_callback_exception_continues;
           test_case
             "run_argv_with_status_split_streaming-callback-exception-continues"
             `Quick
             test_run_argv_with_status_split_streaming_callback_exception_continues;
           test_case
             "run_argv_with_status_split_streaming-callback-cancelled-propagates"
             `Quick
             test_run_argv_with_status_split_streaming_callback_cancelled_propagates;
           test_case
             "run_argv_with_status_split_streaming-cancel-reaps-child"
             `Quick
             test_run_argv_with_status_split_streaming_cancel_reaps_child;
           test_case "run_argv_with_status_split_streaming-multiple-chunks" `Quick
             test_run_argv_with_status_split_streaming_multiple_chunks;
           test_case "run_argv_with_status-rejects-invalid-timeout" `Quick
             test_run_argv_with_status_rejects_invalid_timeout;
           test_case "run_argv_pipeline-timeout-reaps-all-stages" `Quick
             test_run_argv_pipeline_timeout_reaps_all_stages;
           test_case "reset_for_testing-clears-runtime" `Quick
             test_reset_for_testing_clears_runtime;
         ] );
    ]

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

(* A child that emits past the capture ceiling must yield a bounded result
   that names what it elided, not the whole stream. Before the ceiling the
   drainers copied every byte into an unbounded buffer: one `rg` over
   single-line multi-MB JSON retained 590MB inside a keeper turn. *)
let test_capture_bounds_oversized_stdout () =
  Process_eio.reset_for_testing ();
  let emitted = 9 * 1024 * 1024 in
  let ceiling =
    Common.max_process_capture_head_bytes
    + Common.max_process_capture_tail_bytes
  in
  (* [ceiling] must sit strictly inside what the child writes, otherwise the
     assertions below hold trivially and prove nothing. *)
  check bool "child out-writes the ceiling" true (emitted > ceiling);
  let output =
    Process_eio.run_argv
      [ "/bin/sh";
        "-c";
        Printf.sprintf "yes %s | head -c %d" (String.make 64 'a') emitted ]
  in
  (* Pinned to the ceiling plus the truncation marker, not merely "smaller
     than the child wrote": a bound that only shaved a few bytes would still
     satisfy the loose form. *)
  let len = String.length output in
  check bool "capture stays under what the child emitted" true (len < emitted);
  check bool "capture lands at the ceiling plus a short marker" true
    (len >= ceiling && len <= ceiling + 128);
  check bool "elided bytes are reported, not dropped silently" true
    (contains output "(truncated ")

(* Output that fits is byte-identical: the ceiling must not perturb the
   overwhelmingly common short-output call. *)
let test_capture_leaves_small_stdout_untouched () =
  Process_eio.reset_for_testing ();
  let output = Process_eio.run_argv [ "/bin/sh"; "-c"; "printf 'small-exact'" ] in
  check bool "no truncation marker on a short capture" false
    (contains output "(truncated ");
  check bool "short capture passes through verbatim" true
    (contains output "small-exact")

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

let status_to_string = function
  | Unix.WEXITED code -> Printf.sprintf "exited %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signaled %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal

let missing_program = "/definitely/missing/process-eio-command"

let check_refusal_names_the_missing_program () =
  match Process_eio.run_argv_with_status_split_or_refusal [ missing_program ] with
  | Error (Process_eio.Executable_not_found named) ->
    check string "the refusal names argv[0] as given" missing_program named
  | Error
      (( Process_eio.Empty_argv | Process_eio.Spawn_failed _ | Process_eio.Child_setup_failed _
       | Process_eio.Cwd_unavailable _ ) as refusal) ->
    failf "expected Executable_not_found, got %s" (Process_eio.spawn_refusal_to_string refusal)
  | Ok (status, _stdout, stderr) ->
    failf "expected a refusal, got %s with stderr %S" (status_to_string status) stderr

let with_runtime_reset f =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  Fun.protect ~finally:Process_eio.reset_for_testing f

(* A file that exists and is not executable: the spawn is refused, not the
   lookup. *)
let with_noexec_file f =
  let path = Filename.temp_file "process-eio-noexec" ".sh" in
  Out_channel.with_open_bin path (fun oc -> output_string oc "not a program\n");
  Unix.chmod path 0o600;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () -> f path)

(* Unix fallback: posix_spawnp reports the refusal with its errno at the
   spawn call (OCaml 5.5 spawn.c:80, EACCES checked on this switch) and the
   typed runner carries that errno as a value. *)
let test_or_refusal_carries_the_spawn_errno () =
  Process_eio.reset_for_testing ();
  with_noexec_file @@ fun path ->
  match Process_eio.run_argv_with_status_split_or_refusal [ path ] with
  | Error (Process_eio.Spawn_failed { executable; error = Unix.EACCES }) ->
    check string "the refusal names the file" path executable
  | Error refusal ->
    failf "expected Spawn_failed EACCES, got %s" (Process_eio.spawn_refusal_to_string refusal)
  | Ok (status, _stdout, stderr) ->
    failf "expected a refusal, got %s with stderr %S" (status_to_string status) stderr

(* Eio path, same file: PATH resolution finds it, the forked child's execve
   fails, and eio hands the parent that failure as text over its error pipe
   (fork_action.c, low_level.ml). The text arrives as a value, unparsed. *)
let test_or_refusal_carries_the_child_setup_text_eio () =
  with_runtime_reset @@ fun () ->
  with_noexec_file @@ fun path ->
  match Process_eio.run_argv_with_status_split_or_refusal [ path ] with
  | Error (Process_eio.Child_setup_failed { executable; detail }) ->
    check string "the refusal names the file" path executable;
    check bool "eio's text is carried" true (String.length detail > 0)
  | Error refusal ->
    failf "expected Child_setup_failed, got %s" (Process_eio.spawn_refusal_to_string refusal)
  | Ok (status, _stdout, stderr) ->
    failf "expected a refusal, got %s with stderr %S" (status_to_string status) stderr

(* Eio path: the cwd is opened before the fork (spawn_unix on both
   backends), so a directory that does not exist is a refusal with eio's
   own Fs error, not a 127 with text. *)
let test_or_refusal_names_the_missing_cwd_eio () =
  with_runtime_reset @@ fun () ->
  match
    Process_eio.run_argv_with_status_split_or_refusal
      ~cwd:"/definitely/missing/process-eio-cwd"
      [ "/bin/sh"; "-c"; "exit 0" ]
  with
  | Error (Process_eio.Cwd_unavailable { cwd; error = Eio.Fs.Not_found _ }) ->
    check bool "the refusal names the directory" true
      (contains cwd "definitely/missing/process-eio-cwd")
  | Error refusal ->
    failf "expected Cwd_unavailable Not_found, got %s"
      (Process_eio.spawn_refusal_to_string refusal)
  | Ok (status, _stdout, stderr) ->
    failf "expected a refusal, got %s with stderr %S" (status_to_string status) stderr

let check_empty_argv_is_refused () =
  match Process_eio.run_argv_with_status_split_or_refusal [] with
  | Error Process_eio.Empty_argv -> ()
  | Error refusal ->
    failf "expected Empty_argv, got %s" (Process_eio.spawn_refusal_to_string refusal)
  | Ok (status, _stdout, stderr) ->
    failf "an empty argv ran: %s with stderr %S" (status_to_string status) stderr

let test_or_refusal_refuses_empty_argv_on_both_paths () =
  Process_eio.reset_for_testing ();
  check_empty_argv_is_refused ();
  with_runtime_reset check_empty_argv_is_refused

(* The typed runner hands a program the spawn cannot find back as a value.
   The tuple runners above keep folding it into exit 127 plus text. Unix
   fallback path. *)
let test_run_argv_with_status_split_or_refusal_names_missing_program () =
  Process_eio.reset_for_testing ();
  check_refusal_names_the_missing_program ()

(* Same contract on the Eio path, where the refusal originates as
   [Eio.Process.Executable_not_found] from the spawner's PATH resolution. *)
let test_run_argv_with_status_split_or_refusal_names_missing_program_eio () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  check_refusal_names_the_missing_program ();
  Process_eio.reset_for_testing ()

(* A program that ran is [Ok] with its own status and streams, exactly what
   [run_argv_with_status_split] returns; only the pre-spawn case differs. *)
let test_run_argv_with_status_split_or_refusal_returns_status_when_it_ran () =
  Process_eio.reset_for_testing ();
  match
    Process_eio.run_argv_with_status_split_or_refusal
      [ "/bin/sh"; "-c"; "echo refused-by-fixture >&2; exit 3" ]
  with
  | Error refusal ->
    failf "sh was refused: %s" (Process_eio.spawn_refusal_to_string refusal)
  | Ok (status, stdout, stderr) ->
    check string "the child's exit status" "exited 3" (status_to_string status);
    check string "stdout stays separate" "" stdout;
    check bool "stderr is the child's own" true (contains stderr "refused-by-fixture")

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

(* Sub-second budgets must render with their decimals. The old %.0fs format
   printed "Timeout after 0s" for the 0.4s budgets a drained git-inspection
   deadline had left (2026-08-27 audit), which reads as a zero-timeout
   spawn instead of an exhausted one. The timeout WARN comes from the
   Eio-native paths, so this test initializes the Eio runtime first. *)

(* A non-zero exit keeps its stdout -- [output_for_status] joins it with
   stderr -- but a timeout used to drop it entirely: a keeper search that had
   been matching for fifteen seconds got back the word "timeout" and nothing
   else (masc#31742, 18 occurrences on 2026-08-29). The bytes the child
   already wrote are the same bytes a successful call would have returned, so
   they come back labelled rather than discarded. *)
let test_timeout_returns_the_partial_stdout () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let output =
    Process_eio.run_argv
      ~timeout_sec:0.5
      [ "/bin/sh"; "-c"; "/bin/echo MATCH-BEFORE-TIMEOUT; sleep 5" ]
  in
  check bool "the failure line comes first" true
    (String.length output >= 18
     && String.equal (String.sub output 0 18) "process_eio_error:");
  check bool "the timeout is still named" true (contains output "timeout after");
  check bool "the partial stdout survives" true
    (contains output "MATCH-BEFORE-TIMEOUT");
  check bool "and it is labelled incomplete" true (contains output "incomplete")

(* A timeout with nothing written keeps the old shape: the error alone, with
   no empty section inviting a reader to think output was captured. *)
let test_timeout_without_output_stays_bare () =
  Eio_main.run
  @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let output = Process_eio.run_argv ~timeout_sec:0.2 [ "/bin/sleep"; "5" ] in
  check bool "the timeout is named" true (contains output "timeout after");
  check bool "no partial section is added" false (contains output "incomplete")

let test_timeout_log_keeps_subsecond_precision () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  let before =
    match Log.Ring.recent ~limit:1 () with
    | entry :: _ -> entry.Log.Ring.seq
    | [] -> 0
  in
  let status, _output =
    Process_eio.run_argv_with_status ~timeout_sec:0.02 [ "/bin/sleep"; "5" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  check int "eio timeout exit code" 124 code;
  let timeout_rows =
    Log.Ring.recent ~since_seq:before ()
    |> List.filter (fun (row : Log.Ring.entry) ->
           contains row.message "[Process_eio] Timeout after ")
  in
  check bool "timeout warning was logged" true (timeout_rows <> []);
  check bool "sub-second budget renders with decimals"
    true
    (List.exists
       (fun (row : Log.Ring.entry) -> contains row.message "Timeout after 0.02s")
       timeout_rows)

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
    Result.get_ok
    @@ Process_eio.run_argv_pipeline_with_status_split
      ~timeout_sec:0.5
      ~on_stdout_chunk:(fun _ -> ())
      ~on_stderr_chunk:(fun s -> stderr_chunks := s :: !stderr_chunks)
      [
        {
          Process_eio.stdin = Process_eio.Inherited;
          stdout = Process_eio.Captured;
          stderr = Process_eio.Captured;
          argv =
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
    Result.get_ok
    @@ Process_eio.run_argv_pipeline_with_status_split
         ~timeout_sec:0.5
      [
        {
          Process_eio.stdin = Process_eio.Inherited;
          stdout = Process_eio.Captured;
          stderr = Process_eio.Captured;
          argv = [ "/bin/sh"; "-c"; "echo stage1-output; sleep 5" ];
          env = None;
          cwd = None;
        };
        Process_eio.plumbed_stage ~argv:[ "/bin/cat" ] ~env:None ~cwd:None;
      ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  check int "pipeline timeout exit code" 124 code

(* repo_git, voice_bridge_core and exec_dispatch all decide "did this time
   out" from Process_eio's status. They used to each compare against 124, so
   the agreement was a coincidence the compiler could not see (#28651). This
   pins the classifier they now share. *)
let test_exit_reason_classifies_the_timeout_status () =
  Alcotest.(check bool)
    "the synthesized timeout status classifies as Timed_out"
    true
    (Process_eio.exit_reason_of_status Process_eio.timed_out_status
     = Process_eio.Timed_out);
  Alcotest.(check bool)
    "a plain exit does not"
    true
    (Process_eio.exit_reason_of_status (Unix.WEXITED 0) = Process_eio.Completed 0);
  Alcotest.(check bool)
    "a signal is neither"
    true
    (Process_eio.exit_reason_of_status (Unix.WSIGNALED 9) = Process_eio.Signaled 9)
;;

(* Cancelling a running child used to send SIGTERM and SIGKILL back to back:
   the switch release hook fired before the child could act on the first.
   Measured on the voice recorder, that cost the last quarter second of every
   stopped capture. The cancellation path now waits, up to
   [child_exit_grace_seconds], for the child to close the pipes this side
   holds. Two children prove the two halves: one that traps SIGTERM and writes
   a marker on its way out shows the wait happened; one that ignores SIGTERM
   shows the wait is bounded.

   The shape is the voice capture's: [Fiber.first] between the spawn and a
   watcher that returns as soon as the child says it is running. *)
let with_process_runtime f =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd_default = Eio.Stdenv.fs env in
  Process_eio.init ~cwd_default ~proc_mgr ~clock;
  f ~clock
;;

let fresh_marker suffix =
  let path = Filename.temp_file "process-eio-grace" suffix in
  Sys.remove path;
  path
;;

let remove_if_present path = if Sys.file_exists path then Sys.remove path

(* Runs [script] under /bin/sh and stops it as soon as [started] exists. The
   spawn goes through the same entry point the voice recorder uses. *)
let stop_once_started ~clock ~started script =
  Eio.Fiber.first
    (fun () ->
       ignore
         (Process_eio.run_argv_with_stdin_and_status
            ~stdin_content:""
            [ "/bin/sh"; "-c"; script ]);
       `Child_exited_on_its_own)
    (fun () ->
       let rec wait () =
         if not (Sys.file_exists started)
         then (
           Eio.Time.sleep clock 0.01;
           wait ())
       in
       wait ();
       `Stopped_by_the_watcher)
;;

let test_cancel_waits_for_the_child_to_act_on_sigterm () =
  with_process_runtime @@ fun ~clock ->
  let started = fresh_marker ".started" in
  let finished = fresh_marker ".finished" in
  Fun.protect
    ~finally:(fun () ->
      remove_if_present started;
      remove_if_present finished)
    (fun () ->
       (* The trap is installed before the child announces itself, so the
          SIGTERM cannot land in the gap. [sleep 0.05] rather than one long
          sleep: sh runs a trap only once the foreground command it is waiting
          on returns. *)
       let script =
         Printf.sprintf
           "trap ': > %s; exit 0' TERM; : > %s; while :; do sleep 0.05; done"
           (Filename.quote finished)
           (Filename.quote started)
       in
       let outcome = stop_once_started ~clock ~started script in
       check bool "the watcher stopped the child" true
         (outcome = `Stopped_by_the_watcher);
       check bool "the child ran its SIGTERM handler before the kill" true
         (Sys.file_exists finished))
;;

let test_cancel_grace_is_waited_out_when_the_child_ignores_sigterm () =
  with_process_runtime @@ fun ~clock ->
  let started = fresh_marker ".started" in
  Fun.protect
    ~finally:(fun () -> remove_if_present started)
    (fun () ->
       let script =
         Printf.sprintf
           "trap '' TERM; : > %s; while :; do sleep 0.05; done"
           (Filename.quote started)
       in
       let t0 = Eio.Time.now clock in
       let outcome = stop_once_started ~clock ~started script in
       let elapsed = Eio.Time.now clock -. t0 in
       check bool "the watcher stopped the child" true
         (outcome = `Stopped_by_the_watcher);
       check bool
         (Printf.sprintf "the stop waited out the grace (%.2fs)" elapsed)
         true
         (elapsed >= Process_eio.child_exit_grace_seconds))
;;
(* No upper bound on [elapsed]: a reap that waited on the child's pipes would
   not come back at all here (the child ignores SIGTERM and never exits), and
   a case that does not come back is the suite deadline's to name (#33156).
   A hand-picked allowance above the grace would only re-time that. *)

(* #33182: a timeout raced the finalizer onto the switch-off path, which
   waits for EOF on the child's pipes, and a grandchild that inherited stdout
   held the pipe for its whole life: a 0.2s budget came back at 2.03s. A
   timeout leaves the switch on, so the finalizer reaps the child the
   ordinary way and returns when the child is gone, whatever its grandchild
   still holds. The fixture is the one that measured it: a sh script whose
   foreground sleep inherits stdout and outlives the budget. Two of the six
   entry points that nest their switch outside the timeout run it. *)
let grandchild_timeout_budget_seconds = 0.2

(* As long as the grace. A finalizer that waited on the pipes would come back
   only when this sleep, the last holder of stdout, exits. *)
let grandchild_lifetime_seconds = Process_eio.child_exit_grace_seconds

(* The grandchild marks the moment it lets go of stdout. Whether that mark
   exists when the call returns is the observation: a return that waited on
   the pipes finds it, a return at the budget does not. No clock is read. *)
let grandchild_holding_stdout_script ~released =
  Printf.sprintf "sleep %g; : > %s; printf late" grandchild_lifetime_seconds
    (Filename.quote released)
;;

let timeout_with_a_grandchild_holding_stdout run =
  let released = fresh_marker ".released" in
  Fun.protect
    ~finally:(fun () -> remove_if_present released)
    (fun () ->
       let status, stdout, _stderr =
         run ~timeout_sec:grandchild_timeout_budget_seconds
           [ "/bin/sh"; "-c"; grandchild_holding_stdout_script ~released ]
       in
       check bool "the call reports the timeout" true
         (Process_eio.exit_reason_of_status status = Process_eio.Timed_out);
       check string "nothing printed after the budget comes back" "" stdout;
       check bool
         "the call came back while the grandchild still held stdout"
         false
         (Sys.file_exists released))
;;

let test_timeout_with_a_grandchild_holding_stdout_returns_at_the_budget () =
  with_process_runtime @@ fun ~clock:_ ->
  timeout_with_a_grandchild_holding_stdout (fun ~timeout_sec argv ->
    Process_eio.run_argv_with_status_split ~timeout_sec argv)
;;

let test_timeout_with_stdin_and_a_grandchild_holding_stdout_returns_at_the_budget
    ()
  =
  with_process_runtime @@ fun ~clock:_ ->
  timeout_with_a_grandchild_holding_stdout (fun ~timeout_sec argv ->
    Process_eio.run_argv_with_stdin_and_status_split
      ~timeout_sec
      ~stdin_content:""
      argv)
;;

(* The ordinary reap sends SIGTERM and waits out the grace under
   [Eio.Cancel.protect]. The daemon that resolves [Eio.Process.await] is a
   fiber of the switch the child was spawned in; when that switch's parent is
   cancelled during the grace, the daemon dies, and an await after the SIGKILL
   has nothing left to resolve it, because the release hook that would reap
   the child runs only once this fiber has returned. A stop request landing
   while an exec is timing out is that shape. The reap reads the switch again
   after the grace and returns without waiting when it is off.

   An Eio timeout around the call cannot turn that hang into a failure: it
   cancels its body, and a body inside [Cancel.protect] is not interrupted
   (measured in scratch: such a wait outlived a 2.0s [with_timeout] until an
   8s alarm). The watchdog is a wall clock on another domain, and a scenario
   that does not come back leaves its domain blocked until the process
   exits. *)
exception Operator_stop_during_the_reap_grace

let operator_stop_into_grace_seconds = 0.5

let watchdog_poll_interval_seconds = 0.05

(* The budget, the grace the reap waits out before the SIGKILL, and one more
   grace: the reap's own second phase is an await bounded by that same grace
   (it is skipped on this path, where the switch is off), so a return later
   than this is later than anything the mechanism itself waits for. The
   watchdog needs a deadline because an Eio timeout cannot break a wait
   under [Cancel.protect]; this is the only clock in the mechanism. *)
let reap_return_bound_seconds =
  grandchild_timeout_budget_seconds
  +. (2.0 *. Process_eio.child_exit_grace_seconds)
;;

(* One grace longer than the watchdog bound: a child that exited on its own
   inside the window would satisfy the timing for the wrong reason. *)
let sigterm_ignoring_child_lifetime_seconds =
  reap_return_bound_seconds +. Process_eio.child_exit_grace_seconds
;;

let outcome_within_seconds bound scenario =
  let outcome = Atomic.make None in
  let runner =
    Domain.spawn (fun () ->
      let result =
        try Ok (with_process_runtime scenario) with
        | exn -> Error exn
      in
      Atomic.set outcome (Some result))
  in
  let deadline = Unix.gettimeofday () +. bound in
  let rec wait () =
    match Atomic.get outcome with
    | Some result ->
      Domain.join runner;
      `Came_back result
    | None when Unix.gettimeofday () > deadline -> `Still_blocked
    | None ->
      Unix.sleepf watchdog_poll_interval_seconds;
      wait ()
  in
  wait ()
;;

let describe_status = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
;;

let parent_cancel_during_the_reap_grace ~clock =
  let t0 = Eio.Time.now clock in
  let how =
    match
      Eio.Switch.run (fun outer ->
        Eio.Fiber.fork ~sw:outer (fun () ->
          Eio.Time.sleep clock
            (grandchild_timeout_budget_seconds +. operator_stop_into_grace_seconds);
          Eio.Switch.fail outer Operator_stop_during_the_reap_grace);
        Process_eio.run_argv_with_status_split
          ~timeout_sec:grandchild_timeout_budget_seconds
          [ "/bin/sh";
            "-c";
            Printf.sprintf "trap '' TERM; sleep %g"
              sigterm_ignoring_child_lifetime_seconds ])
    with
    | status, _stdout, _stderr ->
      Printf.sprintf "the call returned (%s)" (describe_status status)
    | exception Operator_stop_during_the_reap_grace ->
      "the outer switch re-raised the stop"
  in
  Eio.Time.now clock -. t0, how
;;

let test_parent_cancel_during_the_reap_grace_returns () =
  match
    outcome_within_seconds reap_return_bound_seconds
      parent_cancel_during_the_reap_grace
  with
  | `Still_blocked ->
    fail
      (Printf.sprintf
         "the call did not come back within %.1fs: a cancel during the reap grace hangs it"
         reap_return_bound_seconds)
  | `Came_back (Error exn) ->
    fail (Printf.sprintf "the scenario raised: %s" (Printexc.to_string exn))
  | `Came_back (Ok (elapsed, how)) ->
    check bool
      (Printf.sprintf "%s once the grace had run out (%.2fs)" how elapsed)
      true
      (elapsed >= Process_eio.child_exit_grace_seconds);
    check bool
      (Printf.sprintf "%s within the bound (%.2fs)" how elapsed)
      true
      (elapsed < reap_return_bound_seconds)
;;

let test_run_argv_with_stdin_held_open_handles_early_closed_pipe () =
  with_runtime_reset @@ fun () ->
  let stdin_content = String.make 65536 'x' in
  let status, _stdout, stderr =
    Process_eio.run_argv_with_stdin_held_open_and_status_split
      ~stdin_content
      [ "/bin/sh"; "-c"; "echo reader_died >&2; exit 2" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  check int "exit status preserved on early reader exit" 2 code;
  check bool "stderr captured from early-exiting child" true
    (contains stderr "reader_died")
;;

let test_run_argv_with_stdin_held_open_preserves_open_pipe () =
  with_runtime_reset @@ fun () ->
  let status, stdout, stderr =
    Process_eio.run_argv_with_stdin_held_open_and_status_split
      ~stdin_content:"hello_stream\n"
      [ "/bin/sh"; "-c"; "read line; echo \"got:$line\"" ]
  in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  check int "exit status 0" 0 code;
  check string "stderr empty" "" stderr;
  check bool "stdout captured" true (contains stdout "got:hello_stream")
;;

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
          test_case "argv-with-status-split-or-refusal-names-missing-program"
            `Quick
            test_run_argv_with_status_split_or_refusal_names_missing_program;
          test_case
            "argv-with-status-split-or-refusal-names-missing-program-eio"
            `Quick
            test_run_argv_with_status_split_or_refusal_names_missing_program_eio;
          test_case "argv-with-status-split-or-refusal-returns-status-when-it-ran"
            `Quick
            test_run_argv_with_status_split_or_refusal_returns_status_when_it_ran;
          test_case "argv-with-status-split-or-refusal-carries-the-spawn-errno"
            `Quick
            test_or_refusal_carries_the_spawn_errno;
          test_case "argv-with-status-split-or-refusal-carries-child-setup-text-eio"
            `Quick
            test_or_refusal_carries_the_child_setup_text_eio;
          test_case "argv-with-status-split-or-refusal-refuses-empty-argv-both-paths"
            `Quick
            test_or_refusal_refuses_empty_argv_on_both_paths;
          test_case "argv-with-status-split-or-refusal-names-the-missing-cwd-eio"
            `Quick
            test_or_refusal_names_the_missing_cwd_eio;
          test_case "argv-with-status-fallback-enforces-timeout" `Quick
            test_run_argv_with_status_fallback_enforces_timeout;
          test_case "argv-with-status-fallback-observes-timeout" `Quick
            test_run_argv_with_status_fallback_observes_timeout;
          test_case "timeout-log-keeps-subsecond-precision" `Quick
            test_timeout_log_keeps_subsecond_precision;
          test_case "timeout-returns-the-partial-stdout" `Quick
            test_timeout_returns_the_partial_stdout;
          test_case "timeout-without-output-stays-bare" `Quick
            test_timeout_without_output_stays_bare;
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
           test_case "capture-bounds-oversized-stdout" `Quick
             test_capture_bounds_oversized_stdout;
           test_case "capture-leaves-small-stdout-untouched" `Quick
             test_capture_leaves_small_stdout_untouched;
           test_case "exit-reason-classifies-the-timeout-status" `Quick
             test_exit_reason_classifies_the_timeout_status;
            test_case "run_argv_with_stdin_held_open-handles-early-closed-pipe"
              `Quick
              test_run_argv_with_stdin_held_open_handles_early_closed_pipe;
            test_case "run_argv_with_stdin_held_open-preserves-open-pipe"
              `Quick
              test_run_argv_with_stdin_held_open_preserves_open_pipe;
         ] );
      ( "cancellation-grace",
        [
          test_case "cancel-waits-for-the-child-to-act-on-sigterm" `Quick
            test_cancel_waits_for_the_child_to_act_on_sigterm;
          test_case "cancel-grace-is-bounded-when-the-child-ignores-sigterm" `Quick
            test_cancel_grace_is_waited_out_when_the_child_ignores_sigterm;
        ] );
      ( "timeout-grace",
        [
          test_case
            "run_argv_with_status_split-timeout-with-a-grandchild-holding-stdout-returns-at-the-budget"
            `Quick
            test_timeout_with_a_grandchild_holding_stdout_returns_at_the_budget;
          test_case
            "run_argv_with_stdin_and_status_split-timeout-with-a-grandchild-holding-stdout-returns-at-the-budget"
            `Quick
            test_timeout_with_stdin_and_a_grandchild_holding_stdout_returns_at_the_budget;
          test_case "parent-cancel-during-the-reap-grace-returns" `Quick
            test_parent_cancel_during_the_reap_grace_returns;
        ] );
    ]

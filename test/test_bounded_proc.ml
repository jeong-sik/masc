(** RFC-0109 P0: [Bounded_proc.run_argv_with_timeout] unit tests.

    Four scenarios cover the helper's invariants:
    1. Process exits cleanly within the timeout.
    2. Timeout wins the race AND the OS-level process is terminated by
       Eio's automatic SIGKILL on switch release.
    3. stdout and stderr are captured separately.
    4. stdin is delivered to the child. *)

open Alcotest

let with_env f =
  Eio_main.run @@ fun env ->
  let mono_clock = Eio.Stdenv.mono_clock env in
  let process_mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  f ~mono_clock ~process_mgr ~cwd

(* Process-existence probe: returns [true] when at least one running
   process matches [argv_substring]. Uses [pgrep -f] which scans the
   full argv line. We tolerate a small delay between SIGKILL delivery
   and kernel cleanup by sleeping briefly before probing. *)
let process_exists argv_substring =
  Unix.sleepf 0.2;
  let dev_null = Unix.openfile Filename.null [ Unix.O_WRONLY ] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close dev_null)
    (fun () ->
      let argv = [| "pgrep"; "-f"; argv_substring |] in
      let pid =
        Unix.create_process_env "pgrep" argv (Unix.environment ()) Unix.stdin
          dev_null dev_null
      in
      let rec wait pid =
        try snd (Unix.waitpid [] pid)
        with Unix.Unix_error (Unix.EINTR, _, _) -> wait pid
      in
      match wait pid with
      | Unix.WEXITED 0 -> true
      | _ -> false)

let test_done_within_timeout () =
  with_env @@ fun ~mono_clock ~process_mgr ~cwd ->
  let outcome =
    Bounded_proc.run_argv_with_timeout ~mono_clock ~process_mgr ~cwd
      ~timeout_s:5.0 [ "echo"; "hello" ]
  in
  match outcome with
  | Bounded_proc.Done (Unix.WEXITED 0, out, err) ->
    check string "stdout captured" "hello\n" out;
    check string "stderr empty" "" err
  | Bounded_proc.Done (status, _, _) ->
    failf "expected WEXITED 0, got %s"
      (match status with
       | Unix.WEXITED n -> Printf.sprintf "WEXITED %d" n
       | Unix.WSIGNALED n -> Printf.sprintf "WSIGNALED %d" n
       | Unix.WSTOPPED n -> Printf.sprintf "WSTOPPED %d" n)
  | Bounded_proc.Timeout timeout ->
    failf "unexpected timeout after %.3fs" timeout.elapsed_s

(* Marker string lets the post-timeout pgrep probe distinguish our
   subprocess from unrelated [sleep] commands on the host. *)
let test_timeout_kills_process () =
  with_env @@ fun ~mono_clock ~process_mgr ~cwd ->
  let marker = "__bounded_proc_rfc0109_marker__" in
  let argv =
    [ "sh"
    ; "-c"
    ; Printf.sprintf "printf partial-out; printf partial-err >&2; sleep 10 # %s" marker
    ]
  in
  let outcome =
    Bounded_proc.run_argv_with_timeout ~mono_clock ~process_mgr ~cwd
      ~timeout_s:0.5 argv
  in
  (match outcome with
   | Bounded_proc.Timeout timeout ->
     check (float 0.2) "timeout fired near requested budget" 0.5 timeout.elapsed_s;
     check (float 0.0) "timeout budget preserved" 0.5 timeout.timeout_s;
     check (list string) "argv preserved" argv timeout.argv;
     check string "partial stdout preserved" "partial-out" timeout.stdout;
     check string "partial stderr preserved" "partial-err" timeout.stderr
   | Bounded_proc.Done _ ->
     failf "expected Timeout, got Done");
  check bool "OS process terminated after switch release" false
    (process_exists marker)

let test_stderr_capture () =
  with_env @@ fun ~mono_clock ~process_mgr ~cwd ->
  let outcome =
    Bounded_proc.run_argv_with_timeout ~mono_clock ~process_mgr ~cwd
      ~timeout_s:5.0
      [ "sh"; "-c"; "echo out; echo err >&2" ]
  in
  match outcome with
  | Bounded_proc.Done (Unix.WEXITED 0, out, err) ->
    check string "stdout" "out\n" out;
    check string "stderr" "err\n" err
  | Bounded_proc.Done (status, _, _) ->
    failf "expected WEXITED 0, got %s"
      (match status with
       | Unix.WEXITED n -> Printf.sprintf "WEXITED %d" n
       | Unix.WSIGNALED n -> Printf.sprintf "WSIGNALED %d" n
       | Unix.WSTOPPED n -> Printf.sprintf "WSTOPPED %d" n)
  | Bounded_proc.Timeout timeout ->
    failf "unexpected timeout after %.3fs" timeout.elapsed_s

let test_stdin_delivered () =
  with_env @@ fun ~mono_clock ~process_mgr ~cwd ->
  let payload = "round-trip via stdin\n" in
  let outcome =
    Bounded_proc.run_argv_with_timeout ~mono_clock ~process_mgr ~cwd
      ~stdin_string:payload ~timeout_s:5.0 [ "cat" ]
  in
  match outcome with
  | Bounded_proc.Done (Unix.WEXITED 0, out, _) ->
    check string "stdin echoed back on stdout" payload out
  | Bounded_proc.Done (status, _, _) ->
    failf "expected WEXITED 0, got %s"
      (match status with
       | Unix.WEXITED n -> Printf.sprintf "WEXITED %d" n
       | Unix.WSIGNALED n -> Printf.sprintf "WSIGNALED %d" n
       | Unix.WSTOPPED n -> Printf.sprintf "WSTOPPED %d" n)
  | Bounded_proc.Timeout timeout ->
    failf "unexpected timeout after %.3fs" timeout.elapsed_s

let () =
  run "Bounded_proc"
    [ ( "run_argv_with_timeout"
      , [ test_case "done within timeout" `Quick
            test_done_within_timeout
        ; test_case "timeout kills process" `Quick
            test_timeout_kills_process
        ; test_case "stderr captured" `Quick test_stderr_capture
        ; test_case "stdin delivered" `Quick test_stdin_delivered
        ] )
    ]

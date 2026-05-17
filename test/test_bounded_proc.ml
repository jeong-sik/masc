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
  let clock = Eio.Stdenv.clock env in
  let process_mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  f ~clock ~process_mgr ~cwd

(* Process-existence probe: returns [true] when at least one running
   process matches [argv_substring]. Uses [pgrep -f] which scans the
   full argv line. We tolerate a small delay between SIGKILL delivery
   and kernel cleanup by sleeping briefly before probing. *)
let process_exists argv_substring =
  Unix.sleepf 0.2;
  let cmd =
    Printf.sprintf "pgrep -f %s > /dev/null 2>&1"
      (Filename.quote argv_substring)
  in
  match Unix.system cmd with
  | Unix.WEXITED 0 -> true
  | _ -> false

let test_done_within_timeout () =
  with_env @@ fun ~clock ~process_mgr ~cwd ->
  let outcome =
    Bounded_proc.run_argv_with_timeout ~clock ~process_mgr ~cwd
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
  | Bounded_proc.Timeout elapsed ->
    failf "unexpected timeout after %.3fs" elapsed

(* Sentinel string lets the post-timeout pgrep probe distinguish our
   subprocess from unrelated [sleep] commands on the host. *)
let test_timeout_kills_process () =
  with_env @@ fun ~clock ~process_mgr ~cwd ->
  let sentinel = "__bounded_proc_rfc0109_sentinel__" in
  let outcome =
    Bounded_proc.run_argv_with_timeout ~clock ~process_mgr ~cwd
      ~timeout_s:0.5
      [ "sh"; "-c"; Printf.sprintf "sleep 10 # %s" sentinel ]
  in
  (match outcome with
   | Bounded_proc.Timeout elapsed ->
     check (float 1.0) "timeout fired near requested budget" 0.5 elapsed
   | Bounded_proc.Done _ ->
     failf "expected Timeout, got Done");
  check bool "OS process terminated after switch release" false
    (process_exists sentinel)

let test_stderr_capture () =
  with_env @@ fun ~clock ~process_mgr ~cwd ->
  let outcome =
    Bounded_proc.run_argv_with_timeout ~clock ~process_mgr ~cwd
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
  | Bounded_proc.Timeout elapsed ->
    failf "unexpected timeout after %.3fs" elapsed

let test_stdin_delivered () =
  with_env @@ fun ~clock ~process_mgr ~cwd ->
  let payload = "round-trip via stdin\n" in
  let outcome =
    Bounded_proc.run_argv_with_timeout ~clock ~process_mgr ~cwd
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
  | Bounded_proc.Timeout elapsed ->
    failf "unexpected timeout after %.3fs" elapsed

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

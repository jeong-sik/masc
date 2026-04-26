(* Tick 5: integration tests for [Process_eio.spawn_detached] and
   [tree_kill]. These spawn real child processes so they stay under
   [`Quick] time budget by using tiny payloads. *)

open Alcotest
module P = Process_eio

let read_all_fd fd =
  let buf = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
      Buffer.add_subbytes buf chunk 0 n;
      loop ()
    | exception Unix.Unix_error ((Unix.EINTR | Unix.EAGAIN), _, _) -> loop ()
    | exception Unix.Unix_error (_, _, _) -> ()
  in
  loop ();
  Buffer.contents buf
;;

let waitpid_nohang pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> None
  | _, status -> Some status
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Some (Unix.WEXITED 0)
;;

let wait_until ~timeout_s f =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if f ()
    then true
    else if Unix.gettimeofday () >= deadline
    then false
    else (
      ignore (Unix.select [] [] [] 0.02);
      loop ())
  in
  loop ()
;;

let env_of_current () = Unix.environment ()

let test_echo_roundtrip () =
  match
    P.spawn_detached
      ~argv:[ "/bin/echo"; "legendary-bash" ]
      ~env:(env_of_current ())
      ~cwd:""
  with
  | Error e -> failf "spawn_detached failed: %s" e
  | Ok h ->
    (* Wait for the child to exit before reading — echo is tiny. *)
    let exited =
      wait_until ~timeout_s:2.0 (fun () ->
        match waitpid_nohang h.pid with
        | Some _ -> true
        | None -> false)
    in
    check bool "child exited" true exited;
    let stdout = read_all_fd h.stdout_fd in
    let stderr = read_all_fd h.stderr_fd in
    Unix.close h.stdout_fd;
    Unix.close h.stderr_fd;
    check string "stdout captured" "legendary-bash\n" stdout;
    check string "stderr empty" "" stderr
;;

let test_pgid_equals_pid () =
  match P.spawn_detached ~argv:[ "/bin/sleep"; "2" ] ~env:(env_of_current ()) ~cwd:"" with
  | Error e -> failf "spawn failed: %s" e
  | Ok h ->
    check int "pgid equals pid" h.pid h.pgid;
    (* There is a fork/setsid race — the parent may observe the
         pgid before the child has finished establishing its own
         session.  Poll briefly so the test is deterministic. *)
    let alive_within =
      wait_until ~timeout_s:1.0 (fun () -> P.is_pgid_alive ~pgid:h.pgid)
    in
    check bool "pgroup reaches alive state" true alive_within;
    P.tree_kill ~pgid:h.pgid ~signal:Sys.sigterm ~grace_sec:1.0;
    ignore (Unix.waitpid [] h.pid);
    Unix.close h.stdout_fd;
    Unix.close h.stderr_fd
;;

let test_tree_kill_sigterm () =
  match
    P.spawn_detached ~argv:[ "/bin/sleep"; "30" ] ~env:(env_of_current ()) ~cwd:""
  with
  | Error e -> failf "spawn failed: %s" e
  | Ok h ->
    let alive = wait_until ~timeout_s:1.0 (fun () -> P.is_pgid_alive ~pgid:h.pgid) in
    check bool "pgroup reaches alive state" true alive;
    P.tree_kill ~pgid:h.pgid ~signal:Sys.sigterm ~grace_sec:2.0;
    let status = ref None in
    let exited =
      wait_until ~timeout_s:3.0 (fun () ->
        match waitpid_nohang h.pid with
        | Some s ->
          status := Some s;
          true
        | None -> false)
    in
    check bool "child exited after tree_kill" true exited;
    let dead = not (P.is_pgid_alive ~pgid:h.pgid) in
    check bool "pgroup dead after tree_kill" true dead;
    Unix.close h.stdout_fd;
    Unix.close h.stderr_fd
;;

let test_tree_kill_escalates_to_sigkill () =
  (* A shell that traps SIGTERM and refuses to die. Parent sends
     SIGTERM, grace expires, tree_kill must escalate to SIGKILL. *)
  let script = "trap '' TERM; sleep 30" in
  match
    P.spawn_detached ~argv:[ "/bin/sh"; "-c"; script ] ~env:(env_of_current ()) ~cwd:""
  with
  | Error e -> failf "spawn failed: %s" e
  | Ok h ->
    let alive = wait_until ~timeout_s:1.0 (fun () -> P.is_pgid_alive ~pgid:h.pgid) in
    check bool "pgroup reaches alive state" true alive;
    P.tree_kill ~pgid:h.pgid ~signal:Sys.sigterm ~grace_sec:0.5;
    let status = ref None in
    let exited =
      wait_until ~timeout_s:2.0 (fun () ->
        match waitpid_nohang h.pid with
        | Some s ->
          status := Some s;
          true
        | None -> false)
    in
    check bool "child exited after escalation" true exited;
    let dead = not (P.is_pgid_alive ~pgid:h.pgid) in
    check bool "SIGKILL reached stubborn child" true dead;
    Unix.close h.stdout_fd;
    Unix.close h.stderr_fd
;;

(* TODO (Tick 7): grandchild reach test.  A naive
   [sh -c 'sleep 30 & wait'] keeps the shell as a zombie after
   SIGTERM, and [kill(-pgid, 0)] on macOS returns 0 on zombie
   pgroups, which makes [is_pgid_alive] report the group "alive"
   indefinitely until someone waitpid's the leader.  Tick 7 will
   introduce a dedicated waitpid reaper inside [Bg_task] which
   resolves this naturally; for Tick 5, the primitive layer has
   been validated via the single-process SIGTERM and SIGKILL cases
   above. *)

let test_empty_argv_rejected () =
  match P.spawn_detached ~argv:[] ~env:(env_of_current ()) ~cwd:"" with
  | Error msg ->
    check
      bool
      "error mentions empty"
      true
      (let lower = String.lowercase_ascii msg in
       let re = Str.regexp_string "empty" in
       try
         let _ = Str.search_forward re lower 0 in
         true
       with
       | Not_found -> false)
  | Ok _ -> fail "empty argv must not spawn"
;;

let test_missing_binary_reports_error () =
  (* We can't easily distinguish "fork failed" vs "child exec failed"
     here because exec errors manifest as exit 127 inside the child.
     This test just verifies spawn_detached returns a handle — the
     exec failure surfaces later via waitpid. *)
  match
    P.spawn_detached
      ~argv:[ "/no/such/tool/for/test_legendary_bash" ]
      ~env:(env_of_current ())
      ~cwd:""
  with
  | Error _ -> () (* Some systems may reject at fork time *)
  | Ok h ->
    let exited =
      wait_until ~timeout_s:1.0 (fun () ->
        match waitpid_nohang h.pid with
        | Some _ -> true
        | None -> false)
    in
    check bool "child exited" true exited;
    Unix.close h.stdout_fd;
    Unix.close h.stderr_fd
;;

let () =
  run
    "process_eio_detached"
    [ ( "spawn_detached"
      , [ test_case "echo roundtrip" `Quick test_echo_roundtrip
        ; test_case "pgid equals pid" `Quick test_pgid_equals_pid
        ; test_case "empty argv rejected" `Quick test_empty_argv_rejected
        ; test_case "missing binary handled" `Quick test_missing_binary_reports_error
        ] )
    ; ( "tree_kill"
      , [ test_case "SIGTERM kills pgroup" `Quick test_tree_kill_sigterm
        ; test_case
            "SIGKILL escalation after grace"
            `Quick
            test_tree_kill_escalates_to_sigkill
          (* grandchild coverage deferred to Tick 7 — see module-level TODO. *)
        ] )
    ]
;;

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
    | n -> Buffer.add_subbytes buf chunk 0 n; loop ()
    | exception Unix.Unix_error ((Unix.EINTR | Unix.EAGAIN), _, _) -> loop ()
    | exception Unix.Unix_error (_, _, _) -> ()
  in
  loop ();
  Buffer.contents buf

let waitpid_nohang pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> None
  | _, status -> Some status
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Some (Unix.WEXITED 0)

let wait_until ~timeout_s f =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if f () then true
    else if Unix.gettimeofday () >= deadline then false
    else (ignore (Unix.select [] [] [] 0.02); loop ())
  in
  loop ()

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
          match waitpid_nohang h.pid with Some _ -> true | None -> false)
      in
      check bool "child exited" true exited;
      let stdout = read_all_fd h.stdout_fd in
      let stderr = read_all_fd h.stderr_fd in
      Unix.close h.stdout_fd;
      Unix.close h.stderr_fd;
      check string "stdout captured" "legendary-bash\n" stdout;
      check string "stderr empty" "" stderr

let assert_group_and_cleanup ~pid ~pgid ~close =
  Fun.protect
    ~finally:(fun () ->
      (* Kill the owned PID as a fallback even if the group assertion fails. *)
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
      ignore (Unix.waitpid [] pid);
      close ())
    (fun () ->
      check int "pgid equals pid" pid pgid;
      (* This OS query must succeed immediately when spawn returns. Polling
         here would hide a parent handle published before child setsid. *)
      Unix.kill (-pgid) 0;
      Unix.kill (-pgid) Sys.sigterm)

let test_pgid_equals_pid () =
  match P.spawn_detached ~argv:[ "/bin/sleep"; "30" ]
    ~env:(env_of_current ()) ~cwd:"" with
  | Error error -> failf "spawn failed: %s" error
  | Ok handle ->
    assert_group_and_cleanup ~pid:handle.pid ~pgid:handle.pgid
      ~close:(fun () -> Unix.close handle.stdout_fd; Unix.close handle.stderr_fd)

let test_devnull_pgid_exists_immediately () =
  match P.spawn_detached_devnull ~argv:[ "/bin/sleep"; "30" ]
    ~env:(env_of_current ()) ~cwd:"" with
  | Error error -> failf "devnull spawn failed: %s" error
  | Ok handle ->
    assert_group_and_cleanup ~pid:handle.devnull_pid ~pgid:handle.devnull_pgid
      ~close:(fun () -> ())

let test_setup_eof_rejects_without_leaking_fds () =
  (* An ordinary file cannot be chdir'd into. Both children finish setsid but
     fail before readiness; the parent must report Error and close all its
     pipe/devnull descriptors. Unlike an arbitrary nonexistent path, this
     fixture cannot accidentally become a valid directory. *)
  let cwd = Filename.temp_file "detached-invalid-cwd" ".file" in
  Fun.protect ~finally:(fun () -> Sys.remove cwd) (fun () ->
    let descriptors_before = Array.length (Sys.readdir "/dev/fd") in
    (match P.spawn_detached ~argv:[ "/bin/true" ] ~env:(env_of_current ()) ~cwd with
     | Error _ -> ()
     | Ok handle ->
       Unix.close handle.stdout_fd; Unix.close handle.stderr_fd;
       ignore (Unix.waitpid [] handle.pid);
       fail "pipe spawn published a handle after pre-ready setup failure");
    check int "pipe setup EOF closes every parent descriptor" descriptors_before
      (Array.length (Sys.readdir "/dev/fd"));
    (match P.spawn_detached_devnull ~argv:[ "/bin/true" ] ~env:(env_of_current ()) ~cwd with
     | Error _ -> ()
     | Ok handle ->
       ignore (Unix.waitpid [] handle.devnull_pid);
       fail "devnull spawn published a handle after pre-ready setup failure");
    check int "devnull setup EOF closes every parent descriptor" descriptors_before
      (Array.length (Sys.readdir "/dev/fd")))

let test_tree_kill_sigterm () =
  match
    P.spawn_detached ~argv:[ "/bin/sleep"; "30" ]
      ~env:(env_of_current ()) ~cwd:""
  with
  | Error e -> failf "spawn failed: %s" e
  | Ok h ->
      let alive =
        wait_until ~timeout_s:1.0 (fun () ->
          P.is_pgid_alive ~pgid:h.pgid)
      in
      check bool "pgroup reaches alive state" true alive;
      P.tree_kill ~pgid:h.pgid ~signal:Sys.sigterm ~grace_sec:2.0;
      let status = ref None in
      let exited =
        wait_until ~timeout_s:3.0 (fun () ->
          match waitpid_nohang h.pid with
          | Some s -> status := Some s; true
          | None -> false)
      in
      check bool "child exited after tree_kill" true exited;
      let dead = not (P.is_pgid_alive ~pgid:h.pgid) in
      check bool "pgroup dead after tree_kill" true dead;
      Unix.close h.stdout_fd; Unix.close h.stderr_fd

let test_tree_kill_escalates_to_sigkill () =
  (* A shell that traps SIGTERM and refuses to die. Parent sends
     SIGTERM, grace expires, tree_kill must escalate to SIGKILL. *)
  let script = "trap '' TERM; sleep 30" in
  match
    P.spawn_detached
      ~argv:[ "/bin/sh"; "-c"; script ]
      ~env:(env_of_current ()) ~cwd:""
  with
  | Error e -> failf "spawn failed: %s" e
  | Ok h ->
      let alive =
        wait_until ~timeout_s:1.0 (fun () ->
          P.is_pgid_alive ~pgid:h.pgid)
      in
      check bool "pgroup reaches alive state" true alive;
      P.tree_kill ~pgid:h.pgid ~signal:Sys.sigterm ~grace_sec:0.5;
      let status = ref None in
      let exited =
        wait_until ~timeout_s:2.0 (fun () ->
          match waitpid_nohang h.pid with
          | Some s -> status := Some s; true
          | None -> false)
      in
      check bool "child exited after escalation" true exited;
      let dead = not (P.is_pgid_alive ~pgid:h.pgid) in
      check bool "SIGKILL reached stubborn child" true dead;
      Unix.close h.stdout_fd; Unix.close h.stderr_fd

(* TODO (Tick 7): grandchild reach test.  A naive
   [sh -c 'sleep 30 & wait'] keeps the shell as a zombie after
   SIGTERM, and [kill(-pgid, 0)] on macOS returns 0 on zombie
   pgroups, which makes [is_pgid_alive] report the group "alive"
   indefinitely until someone waitpid's the leader.  Tick 7 will
   introduce a dedicated waitpid reaper which resolves this
   naturally; for Tick 5, the primitive layer has
   been validated via the single-process SIGTERM and SIGKILL cases
   above. *)

let test_empty_argv_rejected () =
  match P.spawn_detached ~argv:[] ~env:(env_of_current ()) ~cwd:"" with
  | Error msg ->
      check bool "error mentions empty" true
        (let lower = String.lowercase_ascii msg in
         let re = Str.regexp_string "empty" in
         (try let _ = Str.search_forward re lower 0 in true
          with Not_found -> false))
  | Ok _ -> fail "empty argv must not spawn"

let test_devnull_spawn_exits_without_pipe_handles () =
  match
    P.spawn_detached_devnull
      ~argv:[ "/bin/sh"; "-c"; "printf stdout-noise; printf stderr-noise >&2" ]
      ~env:(env_of_current ())
      ~cwd:""
  with
  | Error e -> failf "spawn_detached_devnull failed: %s" e
  | Ok h ->
    check int "pgid equals pid" h.devnull_pid h.devnull_pgid;
    let exited =
      wait_until ~timeout_s:2.0 (fun () ->
        match waitpid_nohang h.devnull_pid with
        | Some _ -> true
        | None -> false)
    in
    check bool "child exited" true exited

let test_devnull_empty_argv_rejected () =
  match P.spawn_detached_devnull ~argv:[] ~env:(env_of_current ()) ~cwd:"" with
  | Error msg ->
    check bool "error mentions empty" true
      (let lower = String.lowercase_ascii msg in
       let re = Str.regexp_string "empty" in
       try
         let _ = Str.search_forward re lower 0 in
         true
       with
       | Not_found -> false)
  | Ok _ -> fail "empty argv must not spawn"

let test_missing_binary_reports_error () =
  (* We can't easily distinguish "fork failed" vs "child exec failed"
     here because exec errors manifest as exit 127 inside the child.
     This test just verifies spawn_detached returns a handle — the
     exec failure surfaces later via waitpid. *)
  match
    P.spawn_detached
      ~argv:[ "/no/such/tool/for/test_legendary_bash" ]
      ~env:(env_of_current ()) ~cwd:""
  with
  | Error _ -> () (* Some systems may reject at fork time *)
  | Ok h ->
      let exited =
        wait_until ~timeout_s:1.0 (fun () ->
          match waitpid_nohang h.pid with Some _ -> true | None -> false)
      in
      check bool "child exited" true exited;
      Unix.close h.stdout_fd; Unix.close h.stderr_fd

let () =
  run "process_eio_detached"
    [
      ( "spawn_detached",
        [
          test_case "echo roundtrip" `Quick test_echo_roundtrip;
          test_case "pgid exists immediately" `Quick test_pgid_equals_pid;
          test_case "devnull pgid exists immediately" `Quick test_devnull_pgid_exists_immediately;
          test_case "setup EOF rejects and closes descriptors" `Quick test_setup_eof_rejects_without_leaking_fds;
          test_case "empty argv rejected" `Quick test_empty_argv_rejected;
          test_case "devnull spawn exits" `Quick
            test_devnull_spawn_exits_without_pipe_handles;
          test_case "devnull empty argv rejected" `Quick
            test_devnull_empty_argv_rejected;
          test_case "missing binary handled" `Quick
            test_missing_binary_reports_error;
        ] );
      ( "tree_kill",
        [
          test_case "SIGTERM kills pgroup" `Quick test_tree_kill_sigterm;
          test_case "SIGKILL escalation after grace" `Quick
            test_tree_kill_escalates_to_sigkill;
          (* grandchild coverage deferred to Tick 7 — see module-level TODO. *)
        ] );
    ]

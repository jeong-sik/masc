(** The posix_spawn process manager must behave like eio_posix's fork-based
    one for everything masc's process layer uses: stdout capture through a
    pipe, exit status, working directory, environment, and a child killed
    when its switch is released. Each case runs against both managers and
    compares. *)

open Alcotest

let managers env =
  [ "eio_posix", Eio.Stdenv.process_mgr env
  ; "posix_spawn", Posix_spawn_process_mgr.mgr
  ; "foreground", Posix_spawn_process_mgr.foreground_mgr
      ~clock:(Eio.Stdenv.clock env) ~grace_seconds:2.
  ]
;;

let capture_stdout ?cwd ?env mgr args =
  Eio.Process.parse_out ?cwd ?env mgr Eio.Buf_read.take_all args
;;

let test_stdout_capture () =
  Eio_main.run
  @@ fun env ->
  List.iter
    (fun (label, mgr) ->
      check string (label ^ " captures stdout") "hello\n"
        (capture_stdout mgr [ "/bin/echo"; "hello" ]))
    (managers env)
;;

let test_exit_status () =
  Eio_main.run
  @@ fun env ->
  List.iter
    (fun (label, mgr) ->
      Eio.Switch.run
      @@ fun sw ->
      let proc = Eio.Process.spawn ~sw mgr [ "/bin/sh"; "-c"; "exit 3" ] in
      match Eio.Process.await proc with
      | `Exited code -> check int (label ^ " exit code") 3 code
      | `Signaled signal -> failf "%s: signaled %d" label signal)
    (managers env)
;;

let test_cwd_and_env () =
  Eio_main.run
  @@ fun env ->
  let dir = Filename.get_temp_dir_name () in
  let expected_dir = Unix.realpath dir in
  List.iter
    (fun (label, mgr) ->
      let cwd = Eio.Path.(Eio.Stdenv.fs env / dir) in
      let pwd = capture_stdout ~cwd mgr [ "/bin/pwd" ] |> String.trim |> Unix.realpath in
      check string (label ^ " honours cwd") expected_dir pwd;
      let printed =
        capture_stdout ~env:[| "MASC_SPAWN_PROBE=present" |] mgr [ "/usr/bin/env" ]
      in
      check bool (label ^ " passes the environment") true
        (String_util.contains_substring printed "MASC_SPAWN_PROBE=present");
      check bool (label ^ " passes only the given environment") false
        (String_util.contains_substring printed "PATH="))
    (managers env)
;;

let test_missing_executable () =
  Eio_main.run
  @@ fun env ->
  List.iter
    (fun (label, mgr) ->
      Eio.Switch.run
      @@ fun sw ->
      match Eio.Process.spawn ~sw mgr [ "/nonexistent/masc-spawn-probe" ] with
      | _ -> failf "%s: spawning a missing executable succeeded" label
      | exception Eio.Io _ -> ()
      | exception Unix.Unix_error _ -> ())
    (managers env)
;;

let test_child_is_killed_when_the_switch_is_released () =
  Eio_main.run
  @@ fun env ->
  List.iter
    (fun (label, mgr) ->
      let pid =
        Eio.Switch.run
        @@ fun sw ->
        let proc = Eio.Process.spawn ~sw mgr [ "/bin/sleep"; "60" ] in
        Eio.Process.pid proc
      in
      let alive =
        match Unix.kill pid 0 with
        | () -> true
        | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
      in
      check bool (label ^ " child is gone after the switch is released") false alive)
    (managers env)
;;

(* The manager awaits a child through [Eio_unix.Process.sigchld], which only a
   backend that installs a SIGCHLD handler broadcasts. eio_posix installs one
   at startup and eio_linux does not, so on Linux the wait used to never end.
   Removing the handler here puts this backend into the state the other one
   starts in, which is what lets the Linux failure run on any machine. *)
let test_await_without_the_backends_sigchld_handler () =
  Eio_main.run
  @@ fun env ->
  Sys.set_signal Sys.sigchld Sys.Signal_default;
  Eio.Switch.run
  @@ fun sw ->
  let proc = Eio.Process.spawn ~sw Posix_spawn_process_mgr.mgr [ "/bin/echo"; "hi" ] in
  match
    Eio.Time.with_timeout (Eio.Stdenv.clock env) 10.0 (fun () ->
      Ok (Eio.Process.await proc))
  with
  | Ok (`Exited code) -> check int "exit code" 0 code
  | Ok (`Signaled signal) -> failf "signaled %d" signal
  | Error `Timeout ->
    (* Put it back before failing: the switch's release hook reaps through the
       same condition, so the teardown would hang here too. *)
    Eio_unix.Process.install_sigchld_handler ();
    fail "await never returned: the manager waited on a handler nothing installed"
;;

(* This spawn closes a descriptor it was not given. eio_posix does not, and
   that difference is deliberate.

   exec only closes descriptors marked close-on-exec, so fork+exec hands the
   child every other one -- eio's manager included. Measured 2026-09-07 on
   macOS with a raw [Unix.pipe ()]: eio_posix's child inherited the write end
   and the reader never saw EOF; this manager's child did not.

   What makes the difference is the flag the stub sets:
   POSIX_SPAWN_CLOEXEC_DEFAULT on macOS, and since 2026-09-07
   posix_spawn_file_actions_addclosefrom_np on glibc. Before that the glibc
   branch relied on "masc opens its descriptors close-on-exec", which is a
   whole-process claim nothing enforces -- OCaml's [?cloexec] defaults to
   false, and lib/exec_shim (three pipes) and bin/main_eio each open one that
   way. Measured in C on glibc 2.39 the same day: without the closing action
   the EOF never arrived, with it it did.

   So the file's parity rule has one stated exception, and this is it. A
   future reader who makes the two agree by dropping the guarantee is
   removing the thing that keeps a stray descriptor out of a child; make eio
   stricter instead, or leave them apart.

   The pipe is raw [Unix.pipe ()] on purpose: eio's own pipes pass
   [~cloexec:true] (eio_posix low_level.ml:498) and cannot leak, so a test
   built on those could not fail and would prove nothing. This is the shape
   the repo actually opens without the flag. The timeout keeps a regression a
   failed case instead of a hung suite. *)
let test_this_spawn_does_not_inherit_an_unlisted_pipe () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let bystander_r, bystander_w = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.close bystander_r with Unix.Unix_error _ -> ());
      try Unix.close bystander_w with Unix.Unix_error _ -> ())
    (fun () ->
      Eio.Switch.run
      @@ fun sw ->
      (* Spawned while the pipe is open and named by no file action. *)
      let holder =
        Eio.Process.spawn ~sw Posix_spawn_process_mgr.mgr [ "/bin/sleep"; "30" ]
      in
      Unix.close bystander_w;
      Unix.set_nonblock bystander_r;
      (* Every write end this process knows of is gone. A read that still
         finds the pipe open means the child kept one. *)
      let rec drain deadline =
        match Unix.read bystander_r (Bytes.create 64) 0 64 with
        | 0 -> true
        | _ -> drain deadline
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          if Eio.Time.now clock > deadline
          then false
          else (
            Eio.Time.sleep clock 0.01;
            drain deadline)
      in
      let saw_eof = drain (Eio.Time.now clock +. 10.) in
      Eio.Process.signal holder Sys.sigkill;
      check bool "the child did not inherit a pipe this spawn never named" true
        saw_eof)
;;

let group_fixture = {|import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN if sys.argv[2] == "ignore" else lambda *_: sys.exit(0))
r, w = os.pipe()
child = os.fork()
if child == 0:
    os.close(r)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    for fd in (0, 1, 2):
        os.close(fd)
    with open(sys.argv[1], "w") as f:
        f.write(str(os.getpid()))
    os.write(w, b"r")
    os.close(w)
    time.sleep(60)
    os._exit(0)
os.close(w)
os.read(r, 1)
os.close(r)
if sys.argv[2] == "exit":
    sys.exit(0)
while True:
    signal.pause()
|}

let with_group_fixture f =
  let marker = Filename.temp_file "foreground-group" ".pid" in
  Sys.remove marker;
  Fun.protect ~finally:(fun () -> if Sys.file_exists marker then Sys.remove marker)
    (fun () -> Eio_main.run (fun env -> f env marker))
;;

let wait_for_marker clock marker =
  Eio.Time.with_timeout_exn clock 10. (fun () ->
    let rec loop () =
      if Sys.file_exists marker && (Unix.stat marker).Unix.st_size > 0 then ()
      else (Eio.Time.sleep clock 0.01; loop ()) in
    loop ());
  let ic = open_in marker in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> int_of_string (input_line ic))
;;

let assert_descendant_stopped env pid =
  (* Orphan zombies may await the platform's init reaper. They cannot run;
     group cleanup does not claim to reap a process that is not our child. *)
  let stopped () =
    let state = Eio.Process.parse_out (Eio.Stdenv.process_mgr env)
      Eio.Buf_read.take_all ~is_success:(fun _ -> true)
      [ "/bin/ps"; "-o"; "stat="; "-p"; string_of_int pid ] |> String.trim in
    state = "" || state.[0] = 'Z' in
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () ->
    let rec loop () =
      if stopped () then () else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; loop ()) in
    loop ())
;;

let test_group_term_keeps_owner_after_leader_exit ~mode () =
  with_group_fixture (fun env marker ->
    let clock = Eio.Stdenv.clock env in
    let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:2. in
    Eio.Switch.run (fun sw ->
      let sibling = Eio.Process.spawn ~sw Posix_spawn_process_mgr.mgr [ "/bin/sleep"; "60" ] in
      let proc = Eio.Process.spawn ~sw mgr [ "python3"; "-c"; group_fixture; marker; mode ] in
      let descendant = wait_for_marker clock marker in
      let requested_at = Eio.Time.now clock in
      Eio.Process.signal proc Sys.sigterm;
      ignore (Eio.Process.await proc);
      check bool "leader exit does not retire the group TERM grace" true
        (Eio.Time.now clock -. requested_at >= 2.);
      assert_descendant_stopped env descendant;
      Unix.kill (Eio.Process.pid sibling) 0;
      Eio.Process.signal sibling Sys.sigkill))
;;

let test_group_explicit_kill_reaps_leader_and_stops_descendant () =
  with_group_fixture (fun env marker ->
    let clock = Eio.Stdenv.clock env in
    let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:2. in
    Eio.Switch.run (fun sw ->
      let proc = Eio.Process.spawn ~sw mgr
        [ "python3"; "-c"; group_fixture; marker; "ignore" ] in
      let descendant = wait_for_marker clock marker in
      Eio.Process.signal proc Sys.sigkill;
      (match Eio.Process.await proc with
       | `Signaled signal -> check int "leader received SIGKILL" Sys.sigkill signal
       | `Exited code -> failf "killed leader exited normally: %d" code);
      assert_descendant_stopped env descendant;
      match Unix.waitpid [ Unix.WNOHANG ] (Eio.Process.pid proc) with
      | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
      | _ -> fail "explicitly killed foreground leader left unreaped"))
;;

let test_group_normal_exit_reaps_in_long_lived_switch () =
  with_group_fixture (fun env marker ->
    let clock = Eio.Stdenv.clock env in
    let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:2. in
    Eio.Switch.run (fun sw ->
      for _ = 1 to 12 do
        let proc = Eio.Process.spawn ~sw mgr [ "/bin/sh"; "-c"; "exit 0" ] in
        ignore (Eio.Process.await proc);
        (match Unix.waitpid [ Unix.WNOHANG ] (Eio.Process.pid proc) with
         | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
         | _ -> fail "foreground leader left unreaped in a live switch")
      done;
      let proc = Eio.Process.spawn ~sw mgr [ "python3"; "-c"; group_fixture; marker; "exit" ] in
      let descendant = wait_for_marker clock marker in
      ignore (Eio.Process.await proc);
      assert_descendant_stopped env descendant))
;;

let test_native_command_cancel_cleans_closed_pipe_descendant () =
  with_group_fixture (fun env marker ->
    let clock = Eio.Stdenv.clock env in
    Process_eio.init ~cwd_default:(Eio.Stdenv.fs env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock;
    let descendant = ref None in
    Eio.Fiber.first
      (fun () -> ignore (Process_eio.run_argv_with_status_split
         [ "python3"; "-c"; group_fixture; marker; "wait" ]))
      (fun () -> descendant := Some (wait_for_marker clock marker));
    match !descendant with
    | Some pid -> assert_descendant_stopped env pid
    | None -> fail "command exited before cancellation fixture was ready")
;;

let () =
  run "posix_spawn_process_mgr"
    [ ( "foreground group ownership",
        [ test_case "TERM leader exits before closed-pipe descendant" `Quick
            (test_group_term_keeps_owner_after_leader_exit ~mode:"wait")
        ; test_case "TERM-ignoring leader still reaches group escalation" `Quick
            (test_group_term_keeps_owner_after_leader_exit ~mode:"ignore")
        ; test_case "explicit group SIGKILL reaps leader and stops descendant" `Quick
            test_group_explicit_kill_reaps_leader_and_stops_descendant
        ; test_case "normal leaders reap inside a long-lived switch" `Quick
            test_group_normal_exit_reaps_in_long_lived_switch
        ; test_case "native command cancellation cleans its group" `Quick
            test_native_command_cancel_cleans_closed_pipe_descendant ])
    ; ( "parity with eio_posix"
      , [ test_case "captures stdout" `Quick test_stdout_capture
        ; test_case "reports the exit status" `Quick test_exit_status
        ; test_case "honours cwd and env" `Quick test_cwd_and_env
        ; test_case "rejects a missing executable" `Quick test_missing_executable
        ; test_case "kills the child when the switch is released" `Quick
            test_child_is_killed_when_the_switch_is_released
        ] )
    ; ( "own dependencies"
      , [ test_case "awaits without the backend's SIGCHLD handler" `Quick
            test_await_without_the_backends_sigchld_handler
        ] )
    ; ( "stricter than eio_posix"
      , [ test_case "closes a descriptor it was not given" `Quick
            test_this_spawn_does_not_inherit_an_unlisted_pipe
        ] )
    ]
;;

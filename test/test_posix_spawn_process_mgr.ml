(** The posix_spawn process manager must behave like eio_posix's fork-based
    one for everything masc's process layer uses: stdout capture through a
    pipe, exit status, working directory, environment, and a child killed
    when its switch is released. Each case runs against both managers and
    compares. *)

open Alcotest

let managers env =
  [ "eio_posix", Eio.Stdenv.process_mgr env
  ; "posix_spawn", Posix_spawn_process_mgr.mgr
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

let () =
  run "posix_spawn_process_mgr"
    [ ( "parity with eio_posix"
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
    ]
;;

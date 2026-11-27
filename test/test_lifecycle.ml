(** Test Shutdown module *)

open Masc

let passed = ref 0
let failed = ref 0

let test name fn =
  try
    fn ();
    incr passed;
    Printf.printf "  PASS  %s\n%!" name
  with e ->
    incr failed;
    Printf.printf "  FAIL  %s: %s\n%!" name (Printexc.to_string e)

(* ══════════════════════════════════════════════════════════════
   Shutdown tests
   ══════════════════════════════════════════════════════════════ *)

let () = test "shutdown hooks run registered cleanup hooks" (fun () ->
  Eio_main.run @@ fun _env ->
  let called = ref false in
  Shutdown.register ~name:"run-all-test" ~priority:99 (fun () ->
    called := true);
  Shutdown_hooks.run_all ();
  assert !called)

exception Simulated_switch_shutdown

let rec waitpid_no_intr child_pid =
  try Unix.waitpid [] child_pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_no_intr child_pid

let () = test "shutdown deadline outlives a stuck cancelled switch" (fun () ->
  match Unix.fork () with
  | 0 ->
      (match
         Shutdown.start_process_deadline_watchdog
           ~timeout_s:0.05
       with
       | Error _ -> Unix._exit 25
       | Ok _watchdog ->
           (match
              try
                Eio_main.run @@ fun _env ->
                Eio.Switch.run @@ fun sw ->
                let () =
                  Eio.Fiber.fork_daemon ~sw (fun () ->
                      Eio.Cancel.protect (fun () -> Eio.Fiber.await_cancel ()))
                in
                raise Simulated_switch_shutdown
              with Simulated_switch_shutdown -> `Shutdown_escaped_switch
            with `Shutdown_escaped_switch -> Unix._exit 24))
  | child_pid ->
      let waited_pid, status = waitpid_no_intr child_pid in
      assert (waited_pid = child_pid);
      assert (status = Unix.WEXITED Shutdown.process_deadline_exit_code))

let () = test "shutdown deadline disarm state is explicit" (fun () ->
  let watchdog =
    match
      Shutdown.start_process_deadline_watchdog
        ~timeout_s:1.0
    with
    | Ok watchdog -> watchdog
    | Error error -> failwith (Shutdown.deadline_error_to_string error)
  in
  assert (Shutdown.disarm_deadline_watchdog watchdog = Shutdown.Disarmed);
  assert
    (Shutdown.disarm_deadline_watchdog watchdog = Shutdown.Already_disarmed))

let () = test "shutdown deadline rejects invalid time values" (fun () ->
  assert
    (match
       Shutdown.start_process_deadline_watchdog
         ~timeout_s:nan
     with
     | Error (Shutdown.Non_finite_deadline_timeout _) -> true
     | _ -> false);
  assert
    (match
       Shutdown.start_process_deadline_watchdog
         ~timeout_s:infinity
     with
     | Error (Shutdown.Non_finite_deadline_timeout _) -> true
     | _ -> false);
  assert
    (match
       Shutdown.start_process_deadline_watchdog
         ~timeout_s:0.0
     with
     | Error (Shutdown.Non_positive_deadline_timeout _) -> true
     | _ -> false))

let () = test "shutdown config rejects malformed present values" (fun () ->
  match Unix.fork () with
  | 0 ->
      Unix.putenv "MASC_SHUTDOWN_NOTIFY_DELAY" "0.2";
      Unix.putenv "MASC_SHUTDOWN_CLEANUP_TIMEOUT" "3";
      Unix.putenv "MASC_SHUTDOWN_FORCE_TIMEOUT" "60s";
      (match Shutdown.config_from_env_result () with
       | Error
           (Shutdown.Invalid_config_number
             { field = Shutdown.Force_timeout; raw_value = "60s" }) ->
           Unix._exit 0
       | _ -> Unix._exit 26)
  | child_pid ->
      let waited_pid, status = waitpid_no_intr child_pid in
      assert (waited_pid = child_pid);
      assert (status = Unix.WEXITED 0))

let () = test "watchdog start failure terminates fail-closed" (fun () ->
  match Unix.fork () with
  | 0 ->
      ignore
        (Shutdown.start_process_deadline_watchdog_or_exit
           ~timeout_s:0.0)
  | child_pid ->
      let waited_pid, status = waitpid_no_intr child_pid in
      assert (waited_pid = child_pid);
      assert
        (status =
         Unix.WEXITED Shutdown.process_deadline_start_failure_exit_code))

let () = test "a parked lane does not hold the session switch" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  (* The lane parks on a promise nobody resolves, the way an owner loop parks
     on its wake once the backlog is empty. Returning from the switch would
     join it; the session switch fails instead. The deadline is the harness
     observing a hang, not a bound on the code under test. *)
  let parked, _never = Eio.Promise.create () in
  match
    Eio.Time.with_timeout clock 5. (fun () ->
      Server_session_switch.run (fun ~runtime_sw:_ sw ->
        Eio.Fiber.fork ~sw (fun () -> Eio.Promise.await parked));
      Ok ())
  with
  | Ok () -> ()
  | Error `Timeout -> failwith "the session switch waited for a parked lane")

(* ── Summary ──────────────────────────────────── *)

let () =
  Printf.printf "\nLifecycle tests: %d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1

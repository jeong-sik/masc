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

let () = test "shutdown phases execute in order" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let phases_seen = ref [] in
  let config = Shutdown.{
    notify_delay_s = 0.01;
    drain_timeout_s = 0.05;
    cleanup_timeout_s = 0.1;
    force_timeout_s = 60.0;
  } in
  let state = Shutdown.create ~config () in
  Shutdown.register ~name:"phase-tracker" ~priority:10 (fun () ->
    phases_seen := "cleanup" :: !phases_seen
  );
  let notify_called = ref false in
  let exit_called = ref false in
  Shutdown.initiate state ~clock
    ~reason:"test"
    ~notify_fn:(fun _reason -> notify_called := true)
    ~drain_check:(fun () -> true)
    ~exit_fn:(fun () -> exit_called := true);
  assert !notify_called;
  assert !exit_called;
  assert (List.mem "cleanup" !phases_seen);
  assert (Shutdown.current_phase state = Shutdown.Done)
)

let () = test "shutdown is_shutting_down during execution" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let config = Shutdown.{
    notify_delay_s = 0.0;
    drain_timeout_s = 0.0;
    cleanup_timeout_s = 1.0;
    force_timeout_s = 60.0;
  } in
  let state = Shutdown.create ~config () in
  assert (not (Shutdown.is_shutting_down state));
  let saw_shutting_down = ref false in
  Shutdown.register ~name:"check-phase" ~priority:10 (fun () ->
    saw_shutting_down := Shutdown.is_shutting_down state
  );
  Shutdown.initiate state ~clock
    ~reason:"test2"
    ~notify_fn:(fun _ -> ())
    ~drain_check:(fun () -> true)
    ~exit_fn:(fun () -> ());
  assert !saw_shutting_down
)

let () = test "shutdown ignores duplicate initiate" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let config = Shutdown.{
    notify_delay_s = 0.0;
    drain_timeout_s = 0.0;
    cleanup_timeout_s = 1.0;
    force_timeout_s = 60.0;
  } in
  let state = Shutdown.create ~config () in
  let count = ref 0 in
  Shutdown.register ~name:"counter" ~priority:10 (fun () -> incr count);
  Shutdown.initiate state ~clock ~reason:"first"
    ~notify_fn:(fun _ -> ()) ~drain_check:(fun () -> true) ~exit_fn:(fun () -> ());
  Shutdown.initiate state ~clock ~reason:"second"
    ~notify_fn:(fun _ -> ()) ~drain_check:(fun () -> true) ~exit_fn:(fun () -> ());
  assert (!count = 1)
)

let () = test "inline shutdown hooks run registered cleanup hooks" (fun () ->
  Eio_main.run @@ fun _env ->
  let called = ref false in
  Shutdown.register ~name:"inline-run-all-test" ~priority:99 (fun () ->
    called := true);
  Shutdown_hooks.run_all ();
  assert !called)

exception Simulated_switch_shutdown

let () = test "shutdown deadline outlives a stuck cancelled switch" (fun () ->
  match Unix.fork () with
  | 0 ->
      (match
         Shutdown.start_process_deadline_watchdog
           ~timeout_s:0.05
       with
       | Error _ -> Unix._exit 25
       | Ok _watchdog ->
           (try
              Eio_main.run @@ fun _env ->
              Eio.Switch.run @@ fun sw ->
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  Eio.Cancel.protect (fun () -> Eio.Fiber.await_cancel ());
                  `Stop_daemon);
              raise Simulated_switch_shutdown
            with Simulated_switch_shutdown -> Unix._exit 24);
           Unix._exit 24)
  | child_pid ->
      let waited_pid, status = Unix.waitpid [] child_pid in
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

(* ── Summary ──────────────────────────────────── *)

let () =
  Printf.printf "\nLifecycle tests: %d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1

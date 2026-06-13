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

(* ── Summary ──────────────────────────────────── *)

let () =
  Printf.printf "\nLifecycle tests: %d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1

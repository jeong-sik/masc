(** Regression: the closure handed to
    [Keeper_turn_admission.commit_registration_if_open] must not suspend.

    That function evaluates its argument inside [Stdlib.Mutex.protect
    slot.state_mu]. [Stdlib.Mutex.lock] blocks the OS thread that runs the Eio
    scheduler, so a fiber that suspends while owning [state_mu] can never be
    resumed: the next fiber on the same domain to touch that slot blocks the
    scheduler thread and the whole domain stops. There is no timeout and no
    diagnostic.

    Before the fix, [Keeper_registry_setup] acquired the per-keeper lifecycle
    key lock INSIDE that critical section
    ([put_entry_internal] -> [Keeper_lifecycle_reservation.with_key_lock] ->
    [Cross_context_mutex.with_eio_lock] -> [Eio.Mutex.use_ro], a suspension
    point under contention). The fix hoists the key lock outside the fence.

    A wedged scheduler cannot be observed from inside its own domain — an
    [Eio.Time.with_timeout] fiber would never be scheduled either. The
    watchdog therefore lives in a separate domain, which turns the pre-fix
    behaviour into a clean non-zero exit instead of a hung test process. *)

module Reservation = Masc.Keeper_lifecycle_reservation
module KR = Masc.Keeper_registry
module Admission = Masc.Keeper_turn_admission

let base_path = "/tmp/test_keeper_registry_admission_no_suspend"
let keeper_name = "wedgecheck"
let watchdog_seconds = 30.0

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "agent_name", `String ("agent-" ^ name)
        ; "trace_id", `String ("trace-" ^ name)
        ; "allowed_paths", `List [ `String "*" ]
        ; "autoboot_enabled", `Bool false
        ])
  with
  | Ok m -> m
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

(* Fiber A holds the lifecycle key lock so that fiber B's acquisition of it is
   guaranteed to suspend, then releases it. Fiber C reads the admission slot
   while B is blocked; pre-fix that read blocks the scheduler thread forever,
   because B is parked with state_mu held. *)
let run_interleaving () =
  Eio_main.run (fun _env ->
    KR.clear ();
    Admission.For_testing.reset ();
    let key_lock_taken, set_key_lock_taken = Eio.Promise.create () in
    let release_key_lock, do_release_key_lock = Eio.Promise.create () in
    let registration_done, set_registration_done = Eio.Promise.create () in
    Eio.Fiber.all
      [ (fun () ->
          (* A: own the key lock until the other two fibers have had their turn *)
          Reservation.with_key_lock ~base_path ~keeper_name (fun () ->
            Eio.Promise.resolve set_key_lock_taken ();
            Eio.Promise.await release_key_lock))
      ; (fun () ->
          (* B: fenced registration — must park on the key lock WITHOUT
             holding the admission slot's state_mu *)
          Eio.Promise.await key_lock_taken;
          let meta = make_meta keeper_name in
          let result =
            KR.register_offline_if_admitted ~base_path keeper_name meta
          in
          Eio.Promise.resolve set_registration_done result)
      ; (fun () ->
          (* C: touch the admission slot while B is parked. Pre-fix this call
             blocks the scheduler thread and nothing below ever runs. *)
          Eio.Promise.await key_lock_taken;
          Eio.Fiber.yield ();
          Eio.Fiber.yield ();
          let snapshot = Admission.snapshot_for ~base_path ~keeper_name in
          assert (String.equal snapshot.Admission.snapshot_keeper_name keeper_name);
          (* The slot must be idle: no turn is in flight, only a registration
             is in progress. *)
          assert (Option.is_none snapshot.Admission.snapshot_in_flight);
          Eio.Promise.resolve do_release_key_lock ())
      ];
    match Eio.Promise.await registration_done with
    | Ok _ -> ()
    | Error _ ->
      failwith "fenced registration failed with no shutdown reserved")
;;

let () =
  let finished = Atomic.make false in
  let watchdog =
    Domain.spawn (fun () ->
      let deadline = Unix.gettimeofday () +. watchdog_seconds in
      let rec wait () =
        if Atomic.get finished
        then ()
        else if Unix.gettimeofday () > deadline
        then (
          prerr_endline
            "FAIL: admission slot wedged — the registration commit suspended \
             while holding state_mu (Stdlib.Mutex), so the Eio scheduler \
             thread is blocked and the domain cannot make progress. Acquire \
             the lifecycle key lock outside \
             Keeper_turn_admission.commit_registration_if_open.";
          exit 1)
        else (
          Unix.sleepf 0.05;
          wait ())
      in
      wait ())
  in
  run_interleaving ();
  Atomic.set finished true;
  Domain.join watchdog;
  print_endline
    "PASS: fenced registration parks on the lifecycle key lock without holding \
     the admission slot mutex"
;;

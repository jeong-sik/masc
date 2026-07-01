(* test_keeper_turn_admission.ml — RFC-0225 §3.1 per-keeper turn
   single-flight gate.

   Verifies the admission invariant the 2026-06-10 voice-repeat RCA showed
   was missing: at most one in-flight turn per keeper, the autonomous lane
   skips a busy slot, the chat lane queues with a bounded waiting cap, and
   every release path (normal return, exception, cancellation while
   waiting) restores the slot. *)

open Masc

let failures = ref 0

let check name cond =
  if cond
  then Printf.printf "  ✓ %s\n%!" name
  else (
    incr failures;
    Printf.printf "  ✗ %s\n%!" name)
;;

let base_path = "/tmp/masc_test_turn_admission"
let keeper_name = "admission-keeper"
let reset () = Keeper_turn_admission.For_testing.reset ()

let test_free_slot_admits () =
  reset ();
  Printf.printf "Test 1: free slot admits both lanes\n%!";
  (match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> 41 + 1) with
   | `Ran 42 -> check "run_if_free admits on a free slot" true
   | `Ran _ | `Busy _ -> check "run_if_free admits on a free slot" false);
  match Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () -> "ok") with
  | `Ran "ok" -> check "run_serialized admits on a free slot" true
  | `Ran _ | `Rejected _ -> check "run_serialized admits on a free slot" false
;;

let test_autonomous_skips_in_flight_chat () =
  reset ();
  Printf.printf "Test 2: autonomous lane skips while a chat turn is in flight\n%!";
  Eio.Switch.run (fun sw ->
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      match
        Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release)
      with
      | `Ran () -> ()
      | `Rejected _ -> check "chat turn admitted on a free slot" false);
    Eio.Promise.await started;
    (match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()) with
     | `Busy (Some { Keeper_turn_admission.lane = Chat; _ }) ->
       check "run_if_free reports Busy with the in-flight chat lane" true
     | `Busy _ -> check "run_if_free reports Busy with the in-flight chat lane" false
     | `Ran () -> check "run_if_free must not admit during an in-flight turn" false);
    Eio.Promise.resolve set_release ())
;;

let test_chat_turns_serialize () =
  reset ();
  Printf.printf "Test 3: concurrent chat turns never overlap\n%!";
  let in_flight = ref 0 in
  let max_in_flight = ref 0 in
  let completed = ref 0 in
  Eio.Switch.run (fun sw ->
    for _ = 1 to 4 do
      Eio.Fiber.fork ~sw (fun () ->
        match
          Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
            incr in_flight;
            if !in_flight > !max_in_flight then max_in_flight := !in_flight;
            (* Suspension point inside the turn: an admission bug would let
               another fiber enter here and push [in_flight] to 2. *)
            Eio.Fiber.yield ();
            decr in_flight;
            incr completed)
        with
        | `Ran () -> ()
        | `Rejected _ -> check "no rejection below the waiting cap" false)
    done);
  check "max in-flight turns is exactly 1" (!max_in_flight = 1);
  check "all 4 chat turns completed" (!completed = 4)
;;

let test_distinct_keepers_do_not_block_each_other () =
  reset ();
  Printf.printf "Test 4: distinct keepers have independent turn slots\n%!";
  let keeper_a = keeper_name ^ "-a" in
  let keeper_b = keeper_name ^ "-b" in
  Eio.Switch.run (fun sw ->
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      match
        Keeper_turn_admission.run_serialized ~base_path ~keeper_name:keeper_a (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release)
      with
      | `Ran () -> ()
      | `Rejected _ -> check "first keeper chat turn admitted" false);
    Eio.Promise.await started;
    (match
       Keeper_turn_admission.run_if_free ~base_path ~keeper_name:keeper_b (fun () ->
         true)
     with
     | `Ran true ->
       check "autonomous lane for another keeper runs while first keeper is busy" true
     | `Ran false | `Busy _ ->
       check "autonomous lane for another keeper runs while first keeper is busy" false);
    let other_chat_entered = ref false in
    let other_chat_completed = ref false in
    Eio.Fiber.fork ~sw (fun () ->
      match
        Keeper_turn_admission.run_serialized ~base_path ~keeper_name:keeper_b (fun () ->
          other_chat_entered := true;
          Eio.Fiber.yield ();
          other_chat_completed := true)
      with
      | `Ran () -> ()
      | `Rejected _ -> check "other keeper chat turn is not rejected" false);
    for _ = 1 to 4 do
      Eio.Fiber.yield ()
    done;
    check
      "chat lane for another keeper enters while first keeper is in flight"
      !other_chat_entered;
    check
      "chat lane for another keeper completes before first keeper releases"
      !other_chat_completed;
    Eio.Promise.resolve set_release ())
;;

let test_waiting_cap_rejects () =
  reset ();
  Printf.printf "Test 5: chat requests beyond the waiting cap are rejected\n%!";
  Eio.Switch.run (fun sw ->
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
           Eio.Promise.resolve set_started ();
           Eio.Promise.await release)));
    Eio.Promise.await started;
    (* Park exactly [max_waiting_chat_requests] waiters behind the holder.
       [Fiber.fork] runs the child until its first suspension point, so each
       waiter has joined the queue before the next fork. *)
    for _ = 1 to Keeper_turn_admission.max_waiting_chat_requests do
      Eio.Fiber.fork ~sw (fun () ->
        ignore (Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () -> ())))
    done;
    (match Keeper_turn_admission.For_testing.peek ~base_path ~keeper_name with
     | Some (_, waiting) ->
       check
         (Printf.sprintf
            "queue holds %d waiters (cap %d)"
            waiting
            Keeper_turn_admission.max_waiting_chat_requests)
         (waiting = Keeper_turn_admission.max_waiting_chat_requests)
     | None -> check "slot exists after queueing" false);
    (match Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () -> ()) with
     | `Rejected { Keeper_turn_admission.waiting; in_flight } ->
       check "request beyond the cap is rejected" true;
       check
         "rejection reports a full queue"
         (waiting >= Keeper_turn_admission.max_waiting_chat_requests);
       (match in_flight with
        | Some { Keeper_turn_admission.lane = Chat; _ } ->
          check "rejection reports the in-flight lane" true
        | Some _ | None -> check "rejection reports the in-flight lane" false)
     | `Ran () -> check "request beyond the cap is rejected" false);
    Eio.Promise.resolve set_release ());
  (* The switch only exits after every parked waiter ran; the slot must be
     fully drained. *)
  match Keeper_turn_admission.For_testing.peek ~base_path ~keeper_name with
  | Some (None, 0) -> check "queue fully drained after release" true
  | Some _ | None -> check "queue fully drained after release" false
;;

let test_exception_releases_slot () =
  reset ();
  Printf.printf "Test 6: an exception inside the turn releases the slot\n%!";
  (try
     ignore
       (Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () ->
          failwith "boom"))
   with
   | Failure _ -> ());
  match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()) with
  | `Ran () -> check "slot released after an exception" true
  | `Busy _ -> check "slot released after an exception" false
;;

let test_cancelled_waiter_leaves_queue () =
  reset ();
  Printf.printf "Test 7: a cancelled waiter leaves the queue\n%!";
  Eio.Switch.run (fun sw ->
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
           Eio.Promise.resolve set_started ();
           Eio.Promise.await release)));
    Eio.Promise.await started;
    (* [Fiber.first] cancels the loser: the waiter blocks on the slot, the
       second branch returns immediately, so the waiter is cancelled while
       queued. Its turn body must never run. *)
    Eio.Fiber.first
      (fun () ->
         ignore
           (Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
              check "cancelled waiter must not run its turn" false)))
      (fun () -> ());
    (match Keeper_turn_admission.For_testing.peek ~base_path ~keeper_name with
     | Some (_, 0) -> check "waiting count restored after cancellation" true
     | Some (_, _) | None -> check "waiting count restored after cancellation" false);
    Eio.Promise.resolve set_release ())
;;

let () =
  Eio_main.run @@ fun _env ->
  test_free_slot_admits ();
  test_autonomous_skips_in_flight_chat ();
  test_chat_turns_serialize ();
  test_distinct_keepers_do_not_block_each_other ();
  test_waiting_cap_rejects ();
  test_exception_releases_slot ();
  test_cancelled_waiter_leaves_queue ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_admission checks passed\n%!"
;;

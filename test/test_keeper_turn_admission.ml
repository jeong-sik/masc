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
let reset () =
  Keeper_turn_admission.For_testing.reset ();
  Keeper_chat_queue.For_testing.reset ();
  ignore
    (Keeper_chat_queue.configure_persistence ~base_path
      : Keeper_chat_queue.configure_report)

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

let test_chat_if_free_never_parks () =
  reset ();
  Printf.printf "Test 1b: run_chat_if_free runs only on an immediately free slot\n%!";
  (match Keeper_turn_admission.run_chat_if_free ~base_path ~keeper_name (fun () -> "ok") with
   | `Ran "ok" -> check "run_chat_if_free admits on a free slot" true
   | `Ran _ | `Busy _ -> check "run_chat_if_free admits on a free slot" false);
  Eio.Switch.run (fun sw ->
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
           Eio.Promise.resolve set_started ();
           Eio.Promise.await release)));
    Eio.Promise.await started;
    (match Keeper_turn_admission.run_chat_if_free ~base_path ~keeper_name (fun () -> ()) with
     | `Busy { Keeper_turn_admission.in_flight = Some { lane = Chat; _ }; waiting = 0 } ->
       check "run_chat_if_free reports busy in-flight chat without parking" true
     | `Busy _ ->
       check "run_chat_if_free reports busy in-flight chat without parking" false
     | `Ran () -> check "run_chat_if_free must not run while slot is held" false);
    let parked_ran = ref false in
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
           parked_ran := true)));
    check
      "parked waiter is observable before if-free attempt"
      (Keeper_turn_admission.chat_waiting ~base_path ~keeper_name);
    (match Keeper_turn_admission.run_chat_if_free ~base_path ~keeper_name (fun () -> ()) with
     | `Busy { Keeper_turn_admission.waiting; _ } ->
       check "run_chat_if_free yields to an already parked chat" (waiting > 0)
     | `Ran () -> check "run_chat_if_free must not overtake a parked chat" false);
    check "parked chat did not run before holder release" (not !parked_ran);
    Eio.Promise.resolve set_release ())
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
     | `Busy
         (Keeper_turn_admission.Turn_busy
            (Some { Keeper_turn_admission.lane = Chat; _ })) ->
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
     | `Rejected
         { Keeper_turn_admission.waiting
         ; in_flight
         ; shutdown_operation_id = None
         } ->
       check "request beyond the cap is rejected" true;
       check
         "rejection reports a full queue"
         (waiting >= Keeper_turn_admission.max_waiting_chat_requests);
       (match in_flight with
        | Some { Keeper_turn_admission.lane = Chat; _ } ->
          check "rejection reports the in-flight lane" true
        | Some _ | None -> check "rejection reports the in-flight lane" false)
     | `Rejected { shutdown_operation_id = Some _; _ } ->
       check "queue-cap rejection is not a shutdown" false
     | `Ran () -> check "request beyond the cap is rejected" false);
    let snapshot = Keeper_turn_admission.snapshot_for ~base_path ~keeper_name in
    check
      "snapshot reports the slot was created"
      snapshot.Keeper_turn_admission.snapshot_slot_created;
    check
      "snapshot reports the full waiting queue"
      (snapshot.Keeper_turn_admission.snapshot_waiting
       = Keeper_turn_admission.max_waiting_chat_requests);
    check
      "snapshot reports waiting cap"
      (snapshot.Keeper_turn_admission.snapshot_waiting_cap
       = Keeper_turn_admission.max_waiting_chat_requests);
    check
      "snapshot marks the waiting queue full"
      snapshot.Keeper_turn_admission.snapshot_waiting_full;
    check
      "snapshot counts the rejected chat request"
      (snapshot.Keeper_turn_admission.snapshot_rejected_chat_count = 1);
    let health =
      Keeper_turn_admission.fleet_health_json
        ~base_path
        ~keeper_names:[ keeper_name ]
    in
    let open Yojson.Safe.Util in
    check "fleet health degrades while the queue is full"
      (String.equal "degraded" (health |> member "status" |> to_string));
    check "fleet health exposes full queue count"
      (health |> member "chat_waiting_full_keeper_count" |> to_int = 1);
    check "fleet health exposes rejection counter"
      (health |> member "chat_rejected_total_count" |> to_int = 1);
    check "fleet health names the full queue reason"
      (health |> member "status_reasons" |> to_list
       |> List.map to_string
       |> List.exists (String.equal "chat_waiting_queue_full"));
    Eio.Promise.resolve set_release ());
  (* The switch only exits after every parked waiter ran; the slot must be
     fully drained. *)
  (match Keeper_turn_admission.For_testing.peek ~base_path ~keeper_name with
   | Some (None, 0) -> check "queue fully drained after release" true
   | Some _ | None -> check "queue fully drained after release" false);
  let snapshot = Keeper_turn_admission.snapshot_for ~base_path ~keeper_name in
  check
    "snapshot clears waiting count after release"
    (snapshot.Keeper_turn_admission.snapshot_waiting = 0);
  check
    "snapshot clears full flag after release"
    (not snapshot.Keeper_turn_admission.snapshot_waiting_full);
  check
    "snapshot retains rejection counter after release"
    (snapshot.Keeper_turn_admission.snapshot_rejected_chat_count = 1)
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

let test_autonomous_yields_to_parked_chat () =
  reset ();
  Printf.printf "Test 8: autonomous lane yields to a parked chat request\n%!";
  (* No slot has been created, so nothing can be waiting. *)
  check
    "chat_waiting is false before any turn"
    (not (Keeper_turn_admission.chat_waiting ~base_path ~keeper_name));
  Eio.Switch.run (fun sw ->
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    let parked_ran = ref false in
    (* Holder: an in-flight chat turn occupying the slot. *)
    Eio.Fiber.fork ~sw (fun () ->
      match
        Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release)
      with
      | `Ran () -> ()
      | `Rejected _ -> check "holder chat admitted on a free slot" false);
    Eio.Promise.await started;
    (* Parked waiter: a second chat request queued behind the holder. [fork]
       runs it to its first suspension — the [Eio.Mutex.lock] park — so by the
       time [fork] returns the waiter is counted in [waiting]. *)
    Eio.Fiber.fork ~sw (fun () ->
      match
        Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
          parked_ran := true)
      with
      | `Ran () -> ()
      | `Rejected _ -> check "parked chat is not rejected below the cap" false);
    check
      "chat_waiting reports the parked chat"
      (Keeper_turn_admission.chat_waiting ~base_path ~keeper_name);
    (match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()) with
     | `Busy _ -> check "run_if_free yields (Busy) while a chat is parked" true
     | `Ran () -> check "run_if_free must not admit while a chat is parked" false);
    check
      "parked chat has not run while the holder is in flight"
      (not !parked_ran);
    Eio.Promise.resolve set_release ());
  (* The switch exits only after the parked chat drained; nothing waits now. *)
  check
    "chat_waiting is false after the queue drains"
    (not (Keeper_turn_admission.chat_waiting ~base_path ~keeper_name))
;;

let test_idle_loop_yields_to_parked_chat () =
  reset ();
  Printf.printf
    "Test 9: an idle autonomous loop exits on a parked chat so the chat admits\n%!";
  let autonomous_exited_via_yield = ref false in
  let chat_ran = ref false in
  Eio.Switch.run (fun sw ->
    let autonomous_admitted, set_autonomous_admitted = Eio.Promise.create () in
    (* Autonomous holder: a bounded idle loop modelling the OAS agent loop's
       per-turn-boundary exit check. Each iteration yields (a turn boundary)
       and inspects [chat_waiting]; a parked chat ends the loop early, the
       admission slot releases, and the chat admits by direct handoff. This
       harnesses the admission-level contract; the SDK-level [exit_condition]
       wiring in [Keeper_agent_run] drives the real loop the same way. *)
    Eio.Fiber.fork ~sw (fun () ->
      match
        Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () ->
          Eio.Promise.resolve set_autonomous_admitted ();
          let rec idle_turns n =
            if n <= 0
            then () (* idle budget spent without a chat: ordinary loop end *)
            else if Keeper_turn_admission.chat_waiting ~base_path ~keeper_name
            then autonomous_exited_via_yield := true (* graceful early exit *)
            else (
              Eio.Fiber.yield ();
              idle_turns (n - 1))
          in
          idle_turns 1000)
      with
      | `Ran () -> ()
      | `Busy _ -> check "autonomous lane admits on a free slot" false);
    Eio.Promise.await autonomous_admitted;
    (* Chat parks behind the in-flight autonomous turn. *)
    Eio.Fiber.fork ~sw (fun () ->
      match
        Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
          chat_ran := true)
      with
      | `Ran () -> ()
      | `Rejected _ -> check "parked chat is not rejected below the cap" false));
  check
    "idle loop exited early because a chat was waiting"
    !autonomous_exited_via_yield;
  check "parked chat admitted after the autonomous turn yielded" !chat_ran
;;

let test_autonomous_yields_to_queued_connector_message () =
  reset ();
  Printf.printf
    "Test 10: autonomous lane yields while a connector/dashboard message is queued\n%!";
  (* Sanity: an empty queue lets the autonomous lane run. *)
  (match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> 7) with
   | `Ran 7 -> check "run_if_free admits when the chat queue is empty" true
   | `Ran _ | `Busy _ -> check "run_if_free admits when the chat queue is empty" false);
  (* A busy connector (Slack/Discord) message is deferred on the chat queue
     without parking on the admission slot, so [chat_waiting] stays false. The
     autonomous lane must still yield, or a long/back-to-back autonomous turn
     busy-ACKs the connector forever (the starvation this pins). *)
  (match
     Keeper_chat_queue.enqueue ~keeper_name
       { Keeper_chat_queue.content = "deferred slack mention"
       ; user_blocks = []
       ; attachments = []
       ; timestamp = 1.0
       ; source =
           Keeper_chat_queue.Slack
             { channel_id = "C-test"
             ; user_id = "U-test"
             ; user_name = "slack-user"
             ; team_id = Some "T-test"
             ; thread_ts = Some "171.001"
             }
       }
   with
   | Ok _ -> ()
   | Error error ->
     check
       ("enqueue succeeds: " ^ Keeper_chat_queue.mutation_error_to_string error)
       false);
  let queued = Keeper_chat_queue.snapshot ~keeper_name in
  check "queue depth is 1 after enqueue" (List.length queued.pending = 1);
  check
    "a queued connector message is not a parked chat"
    (not (Keeper_turn_admission.chat_waiting ~base_path ~keeper_name));
  (match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()) with
   | `Busy _ ->
     check "run_if_free yields (Busy) while a connector message is queued" true
   | `Ran () ->
     check "run_if_free must not admit while a connector message is queued" false);
  (* Leasing changes the receipt to Inflight but does not make it disappear.
     The autonomous lane keeps yielding until the terminal decision commits. *)
  let lease =
    match Keeper_chat_queue.lease_batch ~keeper_name with
    | `Leased lease -> Some lease
    | `Empty | `Already_leased _ | `Error _ ->
      check "lease_batch leases the queued connector message" false;
      None
  in
  let inflight = Keeper_chat_queue.snapshot ~keeper_name in
  check "leased receipt remains visible" (List.length inflight.inflight = 1);
  (match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()) with
   | `Busy _ -> check "run_if_free yields while the receipt is inflight" true
   | `Ran () -> check "run_if_free must not overtake an inflight receipt" false);
  (match lease with
   | None -> ()
   | Some lease ->
     (match
        Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
          ~outcome:
            (Keeper_chat_queue.Mark_delivered
               { completed_at = 2.0; outcome_ref = None })
      with
      | `Finalized _ -> ()
      | `Unknown_lease | `Error _ ->
        check "finalize commits the terminal receipt" false));
  let settled = Keeper_chat_queue.snapshot ~keeper_name in
  check
    "queue has no active receipts after finalization"
    (settled.pending = [] && settled.inflight = []);
  match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> "ok") with
  | `Ran "ok" -> check "run_if_free admits again once the queue is drained" true
  | `Ran _ | `Busy _ -> check "run_if_free admits again once the queue is drained" false
;;

let test_shutdown_reservation_fences_and_rolls_back () =
  reset ();
  Printf.printf "Test 11: shutdown reservation fences every turn lane\n%!";
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_turn_admission.begin_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_reserved reservation ->
     check
       "reservation records the requested operation"
       (Keeper_shutdown_types.Operation_id.equal reservation.operation_id operation_id);
     check "idle reservation has no in-flight turn" (Option.is_none reservation.in_flight)
   | Keeper_turn_admission.Shutdown_already_reserved _ ->
     check "fresh slot is not already reserved" false);
  (match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()) with
   | `Busy (Keeper_turn_admission.Shutdown_requested reserved) ->
     check
       "autonomous lane sees typed shutdown fence"
       (Keeper_shutdown_types.Operation_id.equal reserved operation_id)
   | `Busy (Keeper_turn_admission.Turn_busy _) | `Ran () ->
     check "autonomous lane cannot cross shutdown fence" false);
  (match Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () -> ()) with
   | `Rejected { shutdown_operation_id = Some reserved; _ } ->
     check
       "chat lane sees typed shutdown fence"
       (Keeper_shutdown_types.Operation_id.equal reserved operation_id)
   | `Rejected { shutdown_operation_id = None; _ } | `Ran () ->
     check "chat lane cannot cross shutdown fence" false);
  (match
     Keeper_turn_admission.rollback_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_rolled_back -> ()
   | Keeper_turn_admission.Shutdown_not_reserved
   | Keeper_turn_admission.Shutdown_reserved_by_other _ ->
     check "own reservation rolls back" false);
  match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> "open") with
  | `Ran "open" -> check "rollback re-opens admission" true
  | `Ran _ | `Busy _ -> check "rollback re-opens admission" false
;;

let test_shutdown_reservation_restores_durable_owner () =
  reset ();
  Printf.printf "Test 12: durable shutdown owner restores before registration\n%!";
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  let other_operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_turn_admission.restore_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_restored -> ()
   | Keeper_turn_admission.Shutdown_already_restored
   | Keeper_turn_admission.Shutdown_restore_conflict _ ->
     check "fresh durable owner restores" false);
  (match
     Keeper_turn_admission.restore_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_already_restored -> ()
   | Keeper_turn_admission.Shutdown_restored
   | Keeper_turn_admission.Shutdown_restore_conflict _ ->
     check "same durable owner restores idempotently" false);
  (match
     Keeper_turn_admission.restore_shutdown
       ~base_path
       ~keeper_name
       ~operation_id:other_operation_id
   with
   | Keeper_turn_admission.Shutdown_restore_conflict existing ->
     check
       "different durable owner cannot replace restored fence"
       (Keeper_shutdown_types.Operation_id.equal existing operation_id)
   | Keeper_turn_admission.Shutdown_restored
   | Keeper_turn_admission.Shutdown_already_restored ->
     check "different durable owner is rejected" false);
  match
    Keeper_turn_admission.commit_registration_if_open
      ~base_path
      ~keeper_name
      (fun () -> ())
  with
  | Keeper_turn_admission.Registration_shutdown_reserved existing ->
    check
      "registration sees restored durable owner"
      (Keeper_shutdown_types.Operation_id.equal existing operation_id)
  | Keeper_turn_admission.Registration_committed () ->
    check "registration cannot cross restored fence" false
;;

let () =
  Eio_main.run @@ fun _env ->
  test_free_slot_admits ();
  test_chat_if_free_never_parks ();
  test_autonomous_skips_in_flight_chat ();
  test_chat_turns_serialize ();
  test_distinct_keepers_do_not_block_each_other ();
  test_waiting_cap_rejects ();
  test_exception_releases_slot ();
  test_cancelled_waiter_leaves_queue ();
  test_autonomous_yields_to_parked_chat ();
  test_idle_loop_yields_to_parked_chat ();
  test_autonomous_yields_to_queued_connector_message ();
  test_shutdown_reservation_fences_and_rolls_back ();
  test_shutdown_reservation_restores_durable_owner ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_admission checks passed\n%!"
;;

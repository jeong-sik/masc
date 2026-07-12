(* Durable receipt lifecycle tests for Keeper_chat_consumer.

   These tests exercise the consumer through Keeper_chat_queue's public durable
   API.  They intentionally assert receipt states instead of transient queue
   depth so delivery, typed failure, cancellation, and finalization retry remain
   observable across the persistence boundary. *)

open Masc

let failures = ref 0

let check name condition =
  if condition
  then Printf.printf "  ✓ %s\n%!" name
  else (
    incr failures;
    Printf.printf "  ✗ %s\n%!" name)

let check_failure name detail =
  incr failures;
  Printf.printf "  ✗ %s: %s\n%!" name detail

let keeper_name = "consumer-receipt-keeper"

let discord_msg ~content ~channel_id ~user_id ~timestamp =
  { Keeper_chat_queue.content
  ; user_blocks = []
  ; attachments = []
  ; timestamp
  ; source = Keeper_chat_queue.Discord { channel_id; user_id }
  }

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path

let with_env body =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-consumer-receipt-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_chat_queue.For_testing.reset ();
      Keeper_turn_admission.For_testing.reset ();
      let report : Keeper_chat_queue.configure_report =
        Keeper_chat_queue.configure_persistence ~base_path:base
      in
      check "persistence configured without load errors" (report.load_errors = []);
      Fun.protect
        ~finally:(fun () ->
          Keeper_chat_queue.For_testing.reset ();
          Keeper_turn_admission.For_testing.reset ())
        (fun () -> body ~base ~clock))

let enqueue_checked ~label ~keeper_name message =
  match Keeper_chat_queue.enqueue ~keeper_name message with
  | Ok receipt -> Some receipt
  | Error error ->
    check_failure label (Keeper_chat_queue.mutation_error_to_string error);
    None

let await_promise ~clock ~seconds promise =
  Eio.Fiber.first
    (fun () ->
      Eio.Promise.await promise;
      true)
    (fun () ->
      Eio.Time.sleep clock seconds;
      false)

let await_receipt ~clock ~seconds ~keeper_name ~receipt_id ~accept =
  Eio.Fiber.first
    (fun () ->
      let rec loop () =
        match Keeper_chat_queue.lookup_receipt ~keeper_name ~receipt_id with
        | Ok { receipt = Some ({ state; _ } as receipt); _ } when accept state ->
          Some receipt
        | Ok { receipt = Some _ | None; _ } ->
          Eio.Time.sleep clock 0.02;
          loop ()
        | Error error ->
          check_failure "receipt lookup"
            (Keeper_chat_queue.mutation_error_to_string error);
          None
      in
      loop ())
    (fun () ->
      Eio.Time.sleep clock seconds;
      None)

let is_delivered = function
  | Keeper_chat_queue.Delivered _ -> true
  | Pending | Inflight _ | Failed _ -> false

let is_failed = function
  | Keeper_chat_queue.Failed _ -> true
  | Pending | Inflight _ | Delivered _ -> false

let is_inflight = function
  | Keeper_chat_queue.Inflight _ -> true
  | Pending | Delivered _ | Failed _ -> false

let is_pending = function
  | Keeper_chat_queue.Pending -> true
  | Inflight _ | Delivered _ | Failed _ -> false

let receipt_id_in_active receipt_id receipts =
  List.exists
    (fun (receipt : Keeper_chat_queue.active_receipt) ->
       Keeper_chat_queue.Receipt_id.equal receipt.receipt_id receipt_id)
    receipts

let receipt_id_in_terminal receipt_id receipts =
  List.exists
    (fun (receipt : Keeper_chat_queue.receipt_view) ->
       Keeper_chat_queue.Receipt_id.equal receipt.receipt_id receipt_id)
    receipts

let check_terminal_snapshot ~label ~keeper_name ~receipt_id =
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check (label ^ " has no pending receipt")
    (not (receipt_id_in_active receipt_id snapshot.pending));
  check (label ^ " has no inflight receipt")
    (not (receipt_id_in_active receipt_id snapshot.inflight));
  check (label ^ " retains terminal receipt")
    (receipt_id_in_terminal receipt_id snapshot.terminal)

(* [Keeper_chat_consumer.start] owns a process-lifetime polling fiber.  Raising
   from the switch body gives each test a structured teardown and, when a turn
   is active, exercises the same cancellation path as server shutdown. *)
exception Stop_consumer

let with_consumer_switch body =
  try Eio.Switch.run (fun sw -> body sw; raise Stop_consumer) with
  | Stop_consumer -> ()

let test_delivery_finalizes_terminal_receipt () =
  Printf.printf "Test: delivery finalizes a durable terminal receipt\n%!";
  with_env (fun ~base ~clock ->
    match
      enqueue_checked ~label:"delivery enqueue" ~keeper_name
        (discord_msg ~content:"deliver me" ~channel_id:"channel-delivered"
           ~user_id:"user-delivered" ~timestamp:1.0)
    with
    | None -> ()
    | Some accepted ->
      let captured = ref None in
      let handle_turn ~sw:_ ~keeper_name:dispatched_keeper ~delivery_key:_ ~queued_message =
        captured := Some (dispatched_keeper, queued_message);
        Keeper_chat_consumer.Delivered
          { outcome_ref = "trace-delivered#1" }
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        match
          await_receipt ~clock ~seconds:5.0 ~keeper_name
            ~receipt_id:accepted.receipt_id ~accept:is_delivered
        with
        | None -> check "delivery reaches terminal state" false
        | Some receipt ->
          (match receipt.state with
           | Keeper_chat_queue.Delivered completion ->
             check "delivery stores the typed outcome reference"
               (completion.outcome_ref = Some "trace-delivered#1")
           | Pending | Inflight _ | Failed _ ->
             check "delivery state is Delivered" false));
      (match !captured with
       | Some (dispatched_keeper, queued_message) ->
         check "delivery dispatches to the accepted keeper"
           (String.equal dispatched_keeper keeper_name);
         check "delivery preserves queued content"
           (String.equal queued_message.content "deliver me");
         (match queued_message.source with
          | Keeper_chat_queue.Discord { channel_id; user_id } ->
            check "delivery preserves Discord channel"
              (String.equal channel_id "channel-delivered");
            check "delivery preserves Discord user"
              (String.equal user_id "user-delivered")
          | Dashboard | Slack _ -> check "delivery source is Discord" false)
       | None -> check "delivery invokes handle_turn" false);
      check_terminal_snapshot ~label:"delivery" ~keeper_name
        ~receipt_id:accepted.receipt_id)

let test_explicit_failure_finalizes_failed_receipt () =
  Printf.printf "Test: explicit turn failure finalizes a Failed receipt\n%!";
  with_env (fun ~base ~clock ->
    match
      enqueue_checked ~label:"failure enqueue" ~keeper_name
        (discord_msg ~content:"fail explicitly" ~channel_id:"channel-failed"
           ~user_id:"user-failed" ~timestamp:2.0)
    with
    | None -> ()
    | Some accepted ->
      let handle_turn ~sw:_ ~keeper_name:_ ~delivery_key:_ ~queued_message:_ =
        Keeper_chat_consumer.Failed
          { kind = Keeper_chat_queue.Delivery_failed
          ; detail = "connector rejected outbound delivery"
          ; outcome_ref = Some "trace-delivery-failed#1"
          }
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        match
          await_receipt ~clock ~seconds:5.0 ~keeper_name
            ~receipt_id:accepted.receipt_id ~accept:is_failed
        with
        | None -> check "explicit failure reaches terminal state" false
        | Some receipt ->
          (match receipt.state with
           | Keeper_chat_queue.Failed failure ->
             check "failure kind is preserved"
               (failure.kind = Keeper_chat_queue.Delivery_failed);
             check "failure detail is preserved"
               (String.equal failure.detail
                  "connector rejected outbound delivery");
             check "failure outcome reference is preserved"
               (failure.outcome_ref = Some "trace-delivery-failed#1")
           | Pending | Inflight _ | Delivered _ ->
             check "explicit failure state is Failed" false));
      check_terminal_snapshot ~label:"explicit failure" ~keeper_name
        ~receipt_id:accepted.receipt_id)

let test_structured_cancellation_nacks_and_preserves_receipt () =
  Printf.printf "Test: structured cancellation nacks the unchanged receipt\n%!";
  with_env (fun ~base ~clock ->
    match
      enqueue_checked ~label:"cancellation enqueue" ~keeper_name
        (discord_msg ~content:"cancel this turn" ~channel_id:"channel-cancel"
           ~user_id:"user-cancel" ~timestamp:3.0)
    with
    | None -> ()
    | Some accepted ->
      let started, resolve_started = Eio.Promise.create () in
      let never, _resolve_never = Eio.Promise.create () in
      let handle_turn ~sw:_ ~keeper_name:_ ~delivery_key:_ ~queued_message:_ =
        Eio.Promise.resolve resolve_started ();
        Eio.Promise.await never
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        check "cancellable turn starts"
          (await_promise ~clock ~seconds:5.0 started);
        check "receipt is inflight before cancellation"
          (match
             await_receipt ~clock ~seconds:1.0 ~keeper_name
               ~receipt_id:accepted.receipt_id ~accept:is_inflight
           with
           | Some _ -> true
           | None -> false));
      (match
         Keeper_chat_queue.lookup_receipt ~keeper_name
           ~receipt_id:accepted.receipt_id
       with
       | Ok
           { receipt = Some { state = Keeper_chat_queue.Pending; receipt_id }
           ; _
           } ->
         check "cancellation preserves the accepted receipt id"
           (Keeper_chat_queue.Receipt_id.equal receipt_id accepted.receipt_id)
       | Ok
           { receipt =
               Some { state = Inflight _ | Delivered _ | Failed _; _ }
             | None
           ; _
           }
       | Error _ ->
         check "cancellation returns the receipt to Pending" false);
      let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
      check "cancelled receipt remains pending"
        (receipt_id_in_active accepted.receipt_id snapshot.pending);
      check "cancelled receipt is not left inflight"
        (not (receipt_id_in_active accepted.receipt_id snapshot.inflight));
      check "cancelled receipt is not terminal"
        (not (receipt_id_in_terminal accepted.receipt_id snapshot.terminal)))

let test_dispatch_is_concurrent_per_keeper () =
  Printf.printf "Test: queued turns dispatch concurrently across keepers\n%!";
  with_env (fun ~base ~clock ->
    let keeper_a = keeper_name ^ "-a" in
    let keeper_b = keeper_name ^ "-b" in
    match
      ( enqueue_checked ~label:"keeper A enqueue" ~keeper_name:keeper_a
          (discord_msg ~content:"alpha waits" ~channel_id:"channel-a"
             ~user_id:"user-a" ~timestamp:4.0)
      , enqueue_checked ~label:"keeper B enqueue" ~keeper_name:keeper_b
          (discord_msg ~content:"beta proceeds" ~channel_id:"channel-b"
             ~user_id:"user-b" ~timestamp:5.0) )
    with
    | Some accepted_a, Some accepted_b ->
      let first_keeper = ref None in
      let second_keeper = ref None in
      let calls = ref 0 in
      let first_started, resolve_first_started = Eio.Promise.create () in
      let release_first, resolve_release_first = Eio.Promise.create () in
      let second_started, resolve_second_started = Eio.Promise.create () in
      let handle_turn ~sw:_ ~keeper_name:dispatched_keeper ~delivery_key:_ ~queued_message:_ =
        incr calls;
        match !first_keeper with
        | None ->
          first_keeper := Some dispatched_keeper;
          Eio.Promise.resolve resolve_first_started ();
          Eio.Promise.await release_first;
          Keeper_chat_consumer.Delivered
            { outcome_ref = "trace-" ^ dispatched_keeper ^ "#2" }
        | Some first when String.equal first dispatched_keeper ->
          check "one keeper is not dispatched twice concurrently" false;
          Keeper_chat_consumer.Failed
            { kind = Keeper_chat_queue.Internal_error
            ; detail = "duplicate concurrent dispatch in test"
            ; outcome_ref = None
            }
        | Some _ ->
          second_keeper := Some dispatched_keeper;
          Eio.Promise.resolve resolve_second_started ();
          Keeper_chat_consumer.Delivered
            { outcome_ref = "trace-" ^ dispatched_keeper ^ "#2" }
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        check "first keeper dispatch starts"
          (await_promise ~clock ~seconds:5.0 first_started);
        check "other keeper starts while first keeper is blocked"
          (await_promise ~clock ~seconds:2.0 second_started);
        Eio.Promise.resolve resolve_release_first ();
        check "keeper A receipt reaches Delivered"
          (match
             await_receipt ~clock ~seconds:5.0 ~keeper_name:keeper_a
               ~receipt_id:accepted_a.receipt_id ~accept:is_delivered
           with
           | Some _ -> true
           | None -> false);
        check "keeper B receipt reaches Delivered"
          (match
             await_receipt ~clock ~seconds:5.0 ~keeper_name:keeper_b
               ~receipt_id:accepted_b.receipt_id ~accept:is_delivered
           with
           | Some _ -> true
           | None -> false));
      (match (!first_keeper, !second_keeper) with
       | Some first, Some second ->
         check "the concurrent dispatches use different keepers"
           (not (String.equal first second));
         check "both accepted keepers were dispatched"
           ((String.equal first keeper_a && String.equal second keeper_b)
            || (String.equal first keeper_b && String.equal second keeper_a))
       | None, _ | _, None -> check "both keeper dispatches are observed" false);
      check "each keeper turn is handled exactly once" (!calls = 2);
      check_terminal_snapshot ~label:"keeper A delivery" ~keeper_name:keeper_a
        ~receipt_id:accepted_a.receipt_id;
      check_terminal_snapshot ~label:"keeper B delivery" ~keeper_name:keeper_b
        ~receipt_id:accepted_b.receipt_id
    | None, _ | _, None -> ())

let test_finalization_persistence_retry_does_not_redeliver () =
  Printf.printf
    "Test: failed terminal persistence retries without re-running the turn\n%!";
  with_env (fun ~base ~clock ->
    match
      enqueue_checked ~label:"finalization retry enqueue" ~keeper_name
        (discord_msg ~content:"finalize after retry"
           ~channel_id:"channel-finalize-retry" ~user_id:"user-finalize-retry"
           ~timestamp:6.0)
    with
    | None -> ()
    | Some accepted ->
      let calls = ref 0 in
      let handle_turn ~sw:_ ~keeper_name:_ ~delivery_key:_ ~queued_message:_ =
        incr calls;
        Keeper_chat_queue.For_testing.fail_next_persist ();
        Keeper_chat_consumer.Delivered
          { outcome_ref = "trace-finalized-after-retry#3" }
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        match
          await_receipt ~clock ~seconds:5.0 ~keeper_name
            ~receipt_id:accepted.receipt_id ~accept:is_delivered
        with
        | None -> check "terminal persistence is retried" false
        | Some receipt ->
          (match receipt.state with
           | Keeper_chat_queue.Delivered completion ->
             check "retried finalization preserves the outcome reference"
               (completion.outcome_ref = Some "trace-finalized-after-retry#3")
           | Pending | Inflight _ | Failed _ ->
             check "retried finalization reaches Delivered" false));
      check "finalization retry does not re-run handle_turn" (!calls = 1);
      check_terminal_snapshot ~label:"retried finalization" ~keeper_name
        ~receipt_id:accepted.receipt_id)

let test_invalid_delivered_turn_ref_fails_closed () =
  Printf.printf
    "Test: Delivered with an invalid turn_ref becomes a terminal failure\n%!";
  with_env (fun ~base ~clock ->
    match
      enqueue_checked ~label:"invalid turn_ref enqueue" ~keeper_name
        (discord_msg ~content:"invalid delivered ref"
           ~channel_id:"channel-invalid-ref" ~user_id:"user-invalid-ref"
           ~timestamp:6.5)
    with
    | None -> ()
    | Some accepted ->
      let handle_turn ~sw:_ ~keeper_name:_ ~delivery_key:_ ~queued_message:_ =
        Keeper_chat_consumer.Delivered { outcome_ref = "trace#0042" }
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        match
          await_receipt ~clock ~seconds:5.0 ~keeper_name
            ~receipt_id:accepted.receipt_id ~accept:is_failed
        with
        | Some { state = Keeper_chat_queue.Failed failure; _ } ->
          check "invalid Delivered ref is an internal failure"
            (failure.kind = Keeper_chat_queue.Internal_error);
          check "invalid Delivered ref is not persisted as a join key"
            (failure.outcome_ref = None);
          check "invalid Delivered ref has diagnostic detail"
            (String.trim failure.detail <> "")
        | Some { state = Pending | Inflight _ | Delivered _; _ } | None ->
          check "invalid Delivered ref never reaches Delivered" false);
      check_terminal_snapshot ~label:"invalid delivered ref" ~keeper_name
        ~receipt_id:accepted.receipt_id)

let test_invalid_delivery_diagnostic_does_not_block_lane () =
  Printf.printf
    "Test: malformed delivery diagnostics terminate and release the Keeper lane\n%!";
  with_env (fun ~base ~clock ->
    match
      enqueue_checked ~label:"invalid diagnostic enqueue" ~keeper_name
        (discord_msg ~content:"invalid diagnostic" ~channel_id:"channel-invalid"
           ~user_id:"user-invalid" ~timestamp:7.0)
    with
    | None -> ()
    | Some first ->
      let calls = ref 0 in
      let first_started, resolve_first_started = Eio.Promise.create () in
      let release_first, resolve_release_first = Eio.Promise.create () in
      let handle_turn ~sw:_ ~keeper_name:_ ~delivery_key:_
          ~(queued_message : Keeper_chat_queue.queued_message) =
        incr calls;
        if String.equal queued_message.content "invalid diagnostic"
        then (
          Eio.Promise.resolve resolve_first_started ();
          Eio.Promise.await release_first;
          Keeper_chat_consumer.Failed
            { kind = Keeper_chat_queue.Delivery_failed
            ; detail = "HTTP response body: \255"
            ; outcome_ref = Some " delivery:\255 "
            })
        else Keeper_chat_consumer.Delivered { outcome_ref = "trace-next#4" }
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        check "invalid diagnostic turn starts"
          (await_promise ~clock ~seconds:5.0 first_started);
        match
          enqueue_checked ~label:"next lane message enqueue" ~keeper_name
            (discord_msg ~content:"next lane message" ~channel_id:"channel-next"
               ~user_id:"user-next" ~timestamp:8.0)
        with
        | None -> Eio.Promise.resolve resolve_release_first ()
        | Some second ->
          Eio.Promise.resolve resolve_release_first ();
          (match
             await_receipt ~clock ~seconds:5.0 ~keeper_name
               ~receipt_id:first.receipt_id ~accept:is_failed
           with
           | Some { state = Keeper_chat_queue.Failed failure; _ } ->
             check "malformed diagnostic is repaired to valid UTF-8"
               (String.is_valid_utf_8 failure.detail);
             check "original failure kind is preserved"
               (failure.kind = Keeper_chat_queue.Delivery_failed);
             check "invalid failure turn_ref is omitted, never repaired"
               (failure.outcome_ref = None)
           | Some { state = Pending | Inflight _ | Delivered _; _ } | None ->
             check "malformed diagnostic reaches terminal Failed" false);
          check "next queued turn dispatches after repaired terminal outcome"
            (match
               await_receipt ~clock ~seconds:5.0 ~keeper_name
                 ~receipt_id:second.receipt_id ~accept:is_delivered
             with
             | Some _ -> true
             | None -> false));
      check "each lane turn is handled exactly once" (!calls = 2);
      check_terminal_snapshot ~label:"invalid diagnostic" ~keeper_name
        ~receipt_id:first.receipt_id)

let test_shutdown_fence_keeps_receipt_pending_until_rollback () =
  Printf.printf
    "Test: shutdown fence keeps the accepted receipt Pending until rollback\n%!";
  with_env (fun ~base ~clock ->
    match
      enqueue_checked ~label:"shutdown fence enqueue" ~keeper_name
        (discord_msg ~content:"wait through shutdown"
           ~channel_id:"channel-shutdown" ~user_id:"user-shutdown"
           ~timestamp:9.0)
    with
    | None -> ()
    | Some accepted ->
      let operation_id = Keeper_shutdown_types.Operation_id.generate () in
      ignore
        (Keeper_turn_admission.begin_shutdown ~base_path:base ~keeper_name
           ~operation_id
          : Keeper_turn_admission.begin_shutdown_result);
      let calls = ref 0 in
      let handle_turn ~sw:_ ~keeper_name:_ ~delivery_key:_ ~queued_message:_ =
        incr calls;
        Keeper_chat_consumer.Delivered
          { outcome_ref = "trace-shutdown-rollback#1" }
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        Eio.Time.sleep clock 1.2;
        check "consumer does not lease through the shutdown fence" (!calls = 0);
        check "fenced receipt remains Pending"
          (match
             Keeper_chat_queue.lookup_receipt ~keeper_name
               ~receipt_id:accepted.receipt_id
           with
           | Ok { receipt = Some { state = Pending; _ }; _ } -> true
           | Ok { receipt = Some { state = Inflight _ | Delivered _ | Failed _; _ } | None; _ }
           | Error _ -> false);
        (match
           Keeper_turn_admission.rollback_shutdown ~base_path:base ~keeper_name
             ~operation_id
         with
         | Keeper_turn_admission.Shutdown_rolled_back -> ()
         | Keeper_turn_admission.Shutdown_not_reserved
         | Keeper_turn_admission.Shutdown_reserved_by_other _ ->
           check "test shutdown owner rolls back" false);
        check "same receipt delivers after the lane reopens"
          (match
             await_receipt ~clock ~seconds:5.0 ~keeper_name
               ~receipt_id:accepted.receipt_id ~accept:is_delivered
           with
           | Some _ -> true
           | None -> false));
      check "shutdown rollback dispatches the accepted receipt exactly once"
        (!calls = 1);
      check_terminal_snapshot ~label:"shutdown rollback" ~keeper_name
        ~receipt_id:accepted.receipt_id)

let test_typed_admission_race_nacks_then_retries () =
  Printf.printf
    "Test: typed admission race nacks the lease and retries without Failed\n%!";
  with_env (fun ~base ~clock ->
    match
      enqueue_checked ~label:"typed deferral enqueue" ~keeper_name
        (discord_msg ~content:"retry typed deferral"
           ~channel_id:"channel-deferral" ~user_id:"user-deferral"
           ~timestamp:10.0)
    with
    | None -> ()
    | Some accepted ->
      let operation_id = Keeper_shutdown_types.Operation_id.generate () in
      let calls = ref 0 in
      let first_deferred, resolve_first_deferred = Eio.Promise.create () in
      let second_started, resolve_second_started = Eio.Promise.create () in
      let release_second, resolve_release_second = Eio.Promise.create () in
      let handle_turn ~sw:_ ~keeper_name:_ ~delivery_key:_ ~queued_message:_ =
        incr calls;
        if !calls = 1
        then (
          Eio.Promise.resolve resolve_first_deferred ();
          Keeper_chat_consumer.Deferred
            { rejection =
                { Keeper_turn_admission.waiting = 0
                ; in_flight = None
                ; shutdown_operation_id = Some operation_id
                }
            })
        else (
          Eio.Promise.resolve resolve_second_started ();
          Eio.Promise.await release_second;
          Keeper_chat_consumer.Delivered
            { outcome_ref = "trace-typed-deferral#2" })
      in
      with_consumer_switch (fun sw ->
        Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
        check "first leased attempt returns typed Deferred"
          (await_promise ~clock ~seconds:5.0 first_deferred);
        check "typed Deferred returns the same receipt to Pending"
          (match
             await_receipt ~clock ~seconds:2.0 ~keeper_name
               ~receipt_id:accepted.receipt_id ~accept:is_pending
           with
           | Some _ -> true
           | None -> false);
        let after_defer = Keeper_chat_queue.snapshot ~keeper_name in
        check "typed Deferred never creates a terminal Failed receipt"
          (not (receipt_id_in_terminal accepted.receipt_id after_defer.terminal));
        check "consumer retries the same receipt after deferral"
          (await_promise ~clock ~seconds:5.0 second_started);
        Eio.Promise.resolve resolve_release_second ();
        check "retried receipt reaches Delivered"
          (match
             await_receipt ~clock ~seconds:5.0 ~keeper_name
               ~receipt_id:accepted.receipt_id ~accept:is_delivered
           with
           | Some _ -> true
           | None -> false));
      check "typed deferral causes one retry and no duplicate turn" (!calls = 2);
      check_terminal_snapshot ~label:"typed deferral retry" ~keeper_name
        ~receipt_id:accepted.receipt_id)

let () =
  test_delivery_finalizes_terminal_receipt ();
  test_explicit_failure_finalizes_failed_receipt ();
  test_structured_cancellation_nacks_and_preserves_receipt ();
  test_dispatch_is_concurrent_per_keeper ();
  test_finalization_persistence_retry_does_not_redeliver ();
  test_invalid_delivered_turn_ref_fails_closed ();
  test_invalid_delivery_diagnostic_does_not_block_lane ();
  test_shutdown_fence_keeps_receipt_pending_until_rollback ();
  test_typed_admission_race_nacks_then_retries ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_chat_consumer receipt checks passed\n%!"

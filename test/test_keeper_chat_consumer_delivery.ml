(* test_keeper_chat_consumer_delivery.ml — the back half of the connector
   deferred-reply pipeline (RFC-connector-deferred-reply-via-chat-queue).

   The merged fix enqueues a busy connector message onto Keeper_chat_queue; the
   front half (enqueue + queued ACK) is covered by
   test_keeper_busy_connector_deferred. This pins the back half:
   Keeper_chat_consumer drains the queue once the keeper's turn slot frees, routes
   each same-source run as ONE coalesced turn, and hands handle_turn the typed
   Discord source carrying the channel_id — the routing key the Discord delivery
   adapter (Keeper_chat_discord.adapter_loop -> Discord_rest_client) posts to.

   handle_turn is the consumer's injection seam, so this is deterministic with no
   provider and no Discord REST call: a capturing handle_turn records what the
   consumer would have delivered. The literal HTTP POST is Discord_rest_client's
   transport responsibility and is out of scope for this unit (no DI seam). *)

open Masc

let failures = ref 0

let check name cond =
  if cond then Printf.printf "  \xe2\x9c\x93 %s\n%!" name
  else (
    incr failures;
    Printf.printf "  \xe2\x9c\x97 %s\n%!" name)

let keeper_name = "consumer-delivery-keeper"

let discord_msg ~content ~channel_id ~user_id ~ts =
  { Keeper_chat_queue.content
  ; user_blocks = []
  ; attachments = []
  ; timestamp = ts
  ; source = Keeper_chat_queue.Discord { channel_id; user_id }
  }

(* Run [body] with a fresh temp base path, an Eio env, and a clean queue +
   admission slot. *)
let with_env body =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-consumer-deliv-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_consumer.For_testing.clear_after_lease_hook ();
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      Keeper_chat_consumer.For_testing.clear_after_lease_hook ();
      (* Full registry reset, not just [clear ~keeper_name]: several tests
         below use derived names ([keeper_name ^ "-a"/"-b"]) that a prior
         test's dispatch fiber can leave with a message requeued by
         [Keeper_chat_consumer]'s at-least-once nack-on-cancel path (the
         switch teardown between tests can race a fiber that was mid-ack).
         [Keeper_chat_queue.all_keeper_names] is process-global, so the next
         test's consumer would otherwise pick up and dispatch that leaked
         entry too. *)
      Keeper_chat_queue.For_testing.reset ();
      body ~base ~clock)

(* Generously above every [await_or_timeout] window this suite uses (longest
   is 5.0s), so the dispatch watchdog never preempts a [handle_turn] fake that
   is only waiting on a test-controlled promise. *)
let test_dispatch_deadline_sec = 10.0

(* None of these tests exercise a [handle_turn] that outlives
   [test_dispatch_deadline_sec] — that path is [test_dispatch_stall] below.
   Failing loudly here turns a silent hang into a clear assertion if a future
   change makes a fake [handle_turn] block longer than intended. *)
let unexpected_on_stalled ~keeper_name ~queued_message:_ =
  check
    (Printf.sprintf "on_stalled must not fire for keeper=%s in this test" keeper_name)
    false

(* Capture handle_turn calls; resolve [first] on the first call so the test can
   wait without polling. The queue is emptied by the first drain, so the consumer
   does not call handle_turn again. *)
let capturing () =
  let captured = ref [] in
  let resolved = ref false in
  let first, set_first = Eio.Promise.create () in
  let handle_turn ~sw:_ ~keeper_name:kn ~queued_message =
    captured := (kn, queued_message) :: !captured;
    if not !resolved then (
      resolved := true;
      Eio.Promise.resolve set_first ())
  in
  (captured, first, handle_turn)

(* Await [p] but never hang the suite: lose to a timeout and report it. *)
let await_or_timeout ~clock ~secs p =
  Eio.Fiber.first
    (fun () ->
      Eio.Promise.await p;
      `Got)
    (fun () ->
      Eio.Time.sleep clock secs;
      `Timeout)

let await_queue_depth_or_timeout ~clock ~keeper_name ~expected ~secs =
  Eio.Fiber.first
    (fun () ->
      let rec wait () =
        if Keeper_chat_queue.length ~keeper_name = expected
        then `Got
        else (
          Eio.Time.sleep clock 0.05;
          wait ())
      in
      wait ())
    (fun () ->
      Eio.Time.sleep clock secs;
      `Timeout)

(* [Keeper_chat_consumer.start] forks a non-daemon poll fiber that never returns,
   so a normal [Switch.run] would wait on it forever (in production the
   server-wide switch lives for the process lifetime). Force teardown by raising
   inside the switch body, which cancels the poll fiber. *)
exception Stop

let with_consumer_switch f =
  try Eio.Switch.run (fun sw -> f sw; raise Stop) with Stop -> ()

let submit_blocking_approval ~base ~keeper_name ~kind =
  Keeper_approval_queue.submit_pending_blocking
    ~keeper_name
    ~tool_name:"queued_chat_blocking_gate_test"
    ~input:(`Assoc [ "kind", `String kind ])
    ~risk_level:Keeper_approval_queue.Critical
    ~base_path:base
    ~on_resolution:(fun ~approval_id decision ->
      Keeper_approval_queue.blocking_resolution_plan
        ~effect_key:("queued_chat_gate_test:" ^ approval_id)
        ~commit:(fun () ->
          let (_ : Agent_sdk.Hooks.approval_decision) = decision in
          fun () -> ()))
    ()

let resolve_blocking_approval ~base id =
  match
    Keeper_approval_queue.resolve
      ~base_path:base
      ~id
      ~decision:(Agent_sdk.Hooks.Reject "focused queued-chat test cleanup")
  with
  | Ok () -> ()
  | Error err ->
      check
        ("Blocking approval cleanup: "
         ^ Keeper_approval_queue.resolve_error_to_string err)
        false

let has_transport_failure_row ~base ~keeper_name =
  Keeper_chat_store.load ~base_dir:base ~keeper_name
  |> List.exists (fun message ->
         Keeper_chat_store.Row_kind.equal
           message.Keeper_chat_store.kind
           Keeper_chat_store.Row_kind.Transport_failure)

(* Sentinel for the historical failure path: if the consumer dispatches while
   a Blocking approval owns the lane, this writes the exact durable row the
   production body guard used to create before the consumer ACKed the lease. *)
let transport_failure_sentinel ~base calls ~sw:_ ~keeper_name ~queued_message =
  incr calls;
  Keeper_chat_store.append_turn
    ~base_dir:base
    ~keeper_name
    ~user_content:queued_message.Keeper_chat_queue.content
    ~user_attachments:queued_message.attachments
    ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
    ~assistant_content:"sentinel: Blocking precondition was dispatched"
    ()

let drain_after_resolution ~base ~clock ~keeper_name =
  let captured, first, handle_turn = capturing () in
  with_consumer_switch (fun sw ->
    Keeper_chat_consumer.start ~sw ~clock ~base_path:base
      ~dispatch_deadline_sec:test_dispatch_deadline_sec
      ~on_stalled:unexpected_on_stalled ~handle_turn;
    match await_or_timeout ~clock ~secs:5.0 first with
    | `Got -> ()
    | `Timeout -> check "deferred lease drains after approval resolution" false);
  check "deferred lease is delivered exactly once after resolution"
    (List.length !captured = 1);
  check "resolved Blocking gate permits ACK" (Keeper_chat_queue.length ~keeper_name = 0)

let test_prelease_blocking_approval_leaves_message_retryable () =
  Printf.printf
    "Test: pre-lease Blocking ownership leaves queued chat retryable\n%!";
  with_env (fun ~base ~clock ->
    Keeper_chat_queue.configure_persistence ~base_path:base;
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name
         (discord_msg ~content:"wait for approval" ~channel_id:"chan-prelease"
            ~user_id:"u-prelease" ~ts:1.0)
        : string);
    let approval_id =
      submit_blocking_approval ~base ~keeper_name ~kind:"prelease"
    in
    let calls = ref 0 in
    let handle_turn = transport_failure_sentinel ~base calls in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base
        ~dispatch_deadline_sec:test_dispatch_deadline_sec
        ~on_stalled:unexpected_on_stalled ~handle_turn;
      (* The consumer polls immediately; this bounded window lets that first
         admission decision run without waiting for the one-second cadence. *)
      Eio.Time.sleep clock 0.3);
    check "pre-lease gate does not dispatch the queued turn" (!calls = 0);
    check "pre-lease gate leaves the message queued"
      (Keeper_chat_queue.length ~keeper_name = 1);
    check "pre-lease gate creates no transport-failure row"
      (not (has_transport_failure_row ~base ~keeper_name));
    resolve_blocking_approval ~base approval_id;
    drain_after_resolution ~base ~clock ~keeper_name)

let test_postlease_blocking_approval_nacks_without_failure_row () =
  Printf.printf
    "Test: Blocking ownership won after lease nacks queued chat for retry\n%!";
  with_env (fun ~base ~clock ->
    Keeper_chat_queue.configure_persistence ~base_path:base;
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name
         (discord_msg ~content:"approval raced the lease"
            ~channel_id:"chan-postlease" ~user_id:"u-postlease" ~ts:1.0)
        : string);
    let hook_ran, set_hook_ran = Eio.Promise.create () in
    let approval_id = ref None in
    Keeper_chat_consumer.For_testing.set_after_lease_hook
      (fun ~base_path ~keeper_name:leased_keeper ~lease_id ->
        check "post-lease hook receives the active workspace"
          (String.equal base_path base);
        check "post-lease hook receives the leased keeper"
          (String.equal leased_keeper keeper_name);
        check "post-lease hook receives a concrete lease id"
          (String.trim lease_id <> "");
        approval_id :=
          Some
            (submit_blocking_approval ~base:base_path
               ~keeper_name:leased_keeper ~kind:"postlease");
        Eio.Promise.resolve set_hook_ran ());
    let calls = ref 0 in
    let handle_turn = transport_failure_sentinel ~base calls in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base
        ~dispatch_deadline_sec:test_dispatch_deadline_sec
        ~on_stalled:unexpected_on_stalled ~handle_turn;
      (match await_or_timeout ~clock ~secs:5.0 hook_ran with
       | `Got -> ()
       | `Timeout -> check "post-lease race hook ran" false);
      match
        await_queue_depth_or_timeout ~clock ~keeper_name ~expected:1 ~secs:3.0
      with
      | `Got -> ()
      | `Timeout -> check "post-lease Blocking winner nacks the lease" false);
    Keeper_chat_consumer.For_testing.clear_after_lease_hook ();
    check "post-lease Blocking winner does not dispatch" (!calls = 0);
    check "post-lease Blocking winner keeps the message retryable"
      (Keeper_chat_queue.length ~keeper_name = 1);
    check "post-lease Blocking winner creates no transport-failure row"
      (not (has_transport_failure_row ~base ~keeper_name));
    Keeper_chat_queue.For_testing.reset ();
    Keeper_chat_queue.configure_persistence ~base_path:base;
    check "nacked lease replays as queued after restart"
      (Keeper_chat_queue.length ~keeper_name = 1);
    (match !approval_id with
     | Some id -> resolve_blocking_approval ~base id
     | None -> check "post-lease Blocking approval was installed" false);
    drain_after_resolution ~base ~clock ~keeper_name)

let test_drains_discord_to_handle_turn () =
  Printf.printf "Test: consumer drains a Discord queue entry to handle_turn\n%!";
  with_env (fun ~base ~clock ->
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name
         (discord_msg ~content:"are you free now?" ~channel_id:"chan-1"
            ~user_id:"u-1" ~ts:1.0)
        : string);
    let captured, first, handle_turn = capturing () in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base
        ~dispatch_deadline_sec:test_dispatch_deadline_sec
        ~on_stalled:unexpected_on_stalled ~handle_turn;
      (match await_or_timeout ~clock ~secs:5.0 first with
       | `Got -> ()
       | `Timeout -> check "consumer drained within timeout" false));
    match !captured with
    | [ (kn, qm) ] ->
        check "delivered to the bound keeper" (kn = keeper_name);
        (match qm.Keeper_chat_queue.source with
         | Keeper_chat_queue.Discord { channel_id; user_id } ->
             check "routing key is the Discord channel_id" (channel_id = "chan-1");
             check "routing key carries the user_id" (user_id = "u-1")
         | _ -> check "delivered source is Discord" false);
        check "delivered the user's content" (qm.content = "are you free now?")
    | _ -> check "exactly one handle_turn call" false)

let test_coalesces_same_source_run () =
  Printf.printf
    "Test: same-source messages coalesce into one delivered turn\n%!";
  with_env (fun ~base ~clock ->
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name
         (discord_msg ~content:"first" ~channel_id:"chan-9" ~user_id:"u-9" ~ts:1.0)
        : string);
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name
         (discord_msg ~content:"second" ~channel_id:"chan-9" ~user_id:"u-9" ~ts:2.0)
        : string);
    let captured, first, handle_turn = capturing () in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base
        ~dispatch_deadline_sec:test_dispatch_deadline_sec
        ~on_stalled:unexpected_on_stalled ~handle_turn;
      ignore (await_or_timeout ~clock ~secs:5.0 first));
    match !captured with
    | [ (_, qm) ] ->
        check "two same-source messages became one turn"
          (Keeper_chat_queue.length ~keeper_name = 0);
        check "coalesced content keeps the first message"
          (String_util.string_contains_substring ~needle:"first" qm.content);
        check "coalesced content keeps the second message"
          (String_util.string_contains_substring ~needle:"second" qm.content)
    | _ -> check "exactly one coalesced handle_turn call" false)

let test_gates_while_turn_in_flight () =
  Printf.printf "Test: queue is not drained while a turn is in flight\n%!";
  with_env (fun ~base ~clock ->
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name
         (discord_msg ~content:"during busy" ~channel_id:"chan-5" ~user_id:"u-5"
            ~ts:1.0)
        : string);
    let captured, first, handle_turn = capturing () in
    with_consumer_switch (fun sw ->
      (* Hold the admission slot busy in a sibling fiber. *)
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        ignore
          (Keeper_turn_admission.run_serialized ~base_path:base ~keeper_name
             (fun () ->
               Eio.Promise.resolve set_started ();
               Eio.Promise.await release)));
      Eio.Promise.await started;
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base
        ~dispatch_deadline_sec:test_dispatch_deadline_sec
        ~on_stalled:unexpected_on_stalled ~handle_turn;
      (* The first poll runs immediately; if the consumer ignored the in-flight
         gate it would drain within this window. *)
      (match await_or_timeout ~clock ~secs:0.3 first with
       | `Got -> check "consumer must not drain while a turn is in flight" false
       | `Timeout ->
           check "queue stayed put while the turn was in flight"
             (Keeper_chat_queue.length ~keeper_name = 1));
      (* Release the slot; the next poll drains. *)
      Eio.Promise.resolve set_release ();
      (match await_or_timeout ~clock ~secs:5.0 first with
       | `Got -> ()
       | `Timeout -> check "consumer drains once the slot frees" false));
    check "delivered exactly once after release" (List.length !captured = 1))

let test_queued_dispatch_is_per_keeper () =
  Printf.printf "Test: queued dispatch is independent per keeper\n%!";
  with_env (fun ~base ~clock ->
    let keeper_a = keeper_name ^ "-a" in
    let keeper_b = keeper_name ^ "-b" in
    Keeper_chat_queue.clear ~keeper_name:keeper_a;
    Keeper_chat_queue.clear ~keeper_name:keeper_b;
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name:keeper_a
         (discord_msg ~content:"alpha waits" ~channel_id:"chan-a" ~user_id:"u-a"
            ~ts:1.0)
        : string);
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name:keeper_b
         (discord_msg ~content:"beta should pass" ~channel_id:"chan-b"
            ~user_id:"u-b" ~ts:2.0)
        : string);
    let first_keeper = ref None in
    let second_keeper = ref None in
    let first_started, set_first_started = Eio.Promise.create () in
    let release_first, set_release_first = Eio.Promise.create () in
    let second_seen, set_second_seen = Eio.Promise.create () in
    let first_resolved = ref false in
    let second_resolved = ref false in
    let handle_turn ~sw:_ ~keeper_name:kn ~queued_message:_ =
      match !first_keeper with
      | None ->
          first_keeper := Some kn;
          if not !first_resolved then (
            first_resolved := true;
            Eio.Promise.resolve set_first_started ());
          Eio.Promise.await release_first
      | Some first when String.equal first kn ->
          check "same keeper is not dispatched again while its queued turn runs"
            false
      | Some _ ->
          second_keeper := Some kn;
          if not !second_resolved then (
            second_resolved := true;
            Eio.Promise.resolve set_second_seen ())
    in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base
        ~dispatch_deadline_sec:test_dispatch_deadline_sec
        ~on_stalled:unexpected_on_stalled ~handle_turn;
      (match await_or_timeout ~clock ~secs:5.0 first_started with
       | `Got -> ()
       | `Timeout -> check "first queued keeper dispatch started" false);
      (match await_or_timeout ~clock ~secs:0.5 second_seen with
       | `Got ->
           check "another keeper dispatches while first handler is blocked" true
       | `Timeout ->
           check "another keeper dispatches while first handler is blocked" false);
      Eio.Promise.resolve set_release_first);
    match (!first_keeper, !second_keeper) with
    | Some first, Some second ->
        check "second dispatch uses the other keeper"
          ((String.equal first keeper_a && String.equal second keeper_b)
          || (String.equal first keeper_b && String.equal second keeper_a))
    | _ -> check "both keeper dispatches were observed" false)

(* PR-4a (busy-queue lease/ack/nack): a [handle_turn] that never returns must
   not wedge this keeper's queue forever (the L1/L2 root cause — see
   Keeper_chat_queue.mli and Keeper_chat_consumer.mli). The dispatch
   watchdog races [handle_turn] against [dispatch_deadline_sec]; on timeout
   it calls [on_stalled] then acks (not nacks) the lease, since retrying a
   turn [Keeper_msg_async]'s own timeout has already abandoned would not
   help. *)
let test_dispatch_stall_calls_on_stalled_and_acks () =
  Printf.printf
    "Test: a handle_turn that never returns triggers on_stalled and acks \
     (not nacks)\n%!";
  with_env (fun ~base ~clock ->
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name
         (discord_msg ~content:"stuck turn" ~channel_id:"chan-stall"
            ~user_id:"u-stall" ~ts:1.0)
        : string);
    let never, _never_resolve = Eio.Promise.create () in
    let handle_turn ~sw:_ ~keeper_name:_ ~queued_message:_ = Eio.Promise.await never in
    let stalled, set_stalled = Eio.Promise.create () in
    let stalled_call = ref None in
    let on_stalled ~keeper_name:kn ~queued_message:qm =
      stalled_call := Some (kn, qm);
      Eio.Promise.resolve set_stalled ()
    in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base
        ~dispatch_deadline_sec:0.2 ~on_stalled ~handle_turn;
      (match await_or_timeout ~clock ~secs:5.0 stalled with
       | `Got -> ()
       | `Timeout -> check "on_stalled fires once the dispatch deadline elapses" false);
      (* Let the synchronous ack that follows on_stalled land. *)
      Eio.Time.sleep clock 0.3);
    (match !stalled_call with
     | Some (kn, qm) ->
         check "on_stalled sees the bound keeper" (kn = keeper_name);
         check "on_stalled sees the stuck message"
           (String.equal qm.Keeper_chat_queue.content "stuck turn")
     | None -> check "on_stalled was called" false);
    check "the stalled lease is acked, not requeued"
      (Keeper_chat_queue.length ~keeper_name = 0))

let test_failed_nack_persist_retries_without_wedging_keeper () =
  Printf.printf
    "Test: failed nack persistence is retried instead of wedging the keeper\n%!";
  with_env (fun ~base ~clock ->
    Keeper_chat_queue.configure_persistence ~base_path:base;
    ignore
      (Keeper_chat_queue.enqueue ~keeper_name
         (discord_msg ~content:"retry after nack persist" ~channel_id:"chan-retry"
            ~user_id:"u-retry" ~ts:1.0)
        : string);
    let never, _never_resolve = Eio.Promise.create () in
    let handle_turn ~sw:_ ~keeper_name:_ ~queued_message:_ = Eio.Promise.await never in
    let stalled, set_stalled = Eio.Promise.create () in
    let on_stalled ~keeper_name:_ ~queued_message:_ =
      Keeper_chat_queue.For_testing.fail_next_persist ();
      Eio.Promise.resolve set_stalled ();
      failwith "force nack path"
    in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base
        ~dispatch_deadline_sec:0.2 ~on_stalled ~handle_turn;
      (match await_or_timeout ~clock ~secs:5.0 stalled with
       | `Got -> ()
       | `Timeout -> check "stalled callback fires before nack retry" false);
      match
        await_queue_depth_or_timeout ~clock ~keeper_name ~expected:1 ~secs:3.0
      with
      | `Got -> check "failed nack persistence is retried and requeues" true
      | `Timeout ->
        check "failed nack persistence is retried and requeues" false))

let () =
  test_prelease_blocking_approval_leaves_message_retryable ();
  test_postlease_blocking_approval_nacks_without_failure_row ();
  test_drains_discord_to_handle_turn ();
  test_coalesces_same_source_run ();
  test_gates_while_turn_in_flight ();
  test_queued_dispatch_is_per_keeper ();
  test_dispatch_stall_calls_on_stalled_and_acks ();
  test_failed_nack_persist_retries_without_wedging_keeper ();
  if !failures > 0 then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_chat_consumer_delivery checks passed\n%!"

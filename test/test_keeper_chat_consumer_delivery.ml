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
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      Keeper_chat_queue.clear ~keeper_name;
      body ~base ~clock)

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

(* [Keeper_chat_consumer.start] forks a non-daemon poll fiber that never returns,
   so a normal [Switch.run] would wait on it forever (in production the
   server-wide switch lives for the process lifetime). Force teardown by raising
   inside the switch body, which cancels the poll fiber. *)
exception Stop

let with_consumer_switch f =
  try Eio.Switch.run (fun sw -> f sw; raise Stop) with Stop -> ()

let test_drains_discord_to_handle_turn () =
  Printf.printf "Test: consumer drains a Discord queue entry to handle_turn\n%!";
  with_env (fun ~base ~clock ->
    Keeper_chat_queue.enqueue ~keeper_name
      (discord_msg ~content:"are you free now?" ~channel_id:"chan-1"
         ~user_id:"u-1" ~ts:1.0);
    let captured, first, handle_turn = capturing () in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
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
    Keeper_chat_queue.enqueue ~keeper_name
      (discord_msg ~content:"first" ~channel_id:"chan-9" ~user_id:"u-9" ~ts:1.0);
    Keeper_chat_queue.enqueue ~keeper_name
      (discord_msg ~content:"second" ~channel_id:"chan-9" ~user_id:"u-9" ~ts:2.0);
    let captured, first, handle_turn = capturing () in
    with_consumer_switch (fun sw ->
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
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
    Keeper_chat_queue.enqueue ~keeper_name
      (discord_msg ~content:"during busy" ~channel_id:"chan-5" ~user_id:"u-5"
         ~ts:1.0);
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
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
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
    Keeper_chat_queue.enqueue ~keeper_name:keeper_a
      (discord_msg ~content:"alpha waits" ~channel_id:"chan-a" ~user_id:"u-a"
         ~ts:1.0);
    Keeper_chat_queue.enqueue ~keeper_name:keeper_b
      (discord_msg ~content:"beta should pass" ~channel_id:"chan-b"
         ~user_id:"u-b" ~ts:2.0);
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
      Keeper_chat_consumer.start ~sw ~clock ~base_path:base ~handle_turn;
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

let () =
  test_drains_discord_to_handle_turn ();
  test_coalesces_same_source_run ();
  test_gates_while_turn_in_flight ();
  test_queued_dispatch_is_per_keeper ();
  if !failures > 0 then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_chat_consumer_delivery checks passed\n%!"

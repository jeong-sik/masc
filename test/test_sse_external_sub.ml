(** SSE External Subscriber Tests

    Verifies that Sse.subscribe_external / unsubscribe_external
    correctly hooks into the broadcast fan-out path.

    Also hosts the SSE connection close-race regression
    (Server_mcp_transport_http_conn), which shares this file's domain-contention
    harness. *)

module Conn = Server_mcp_transport_http_conn

let received_events : string list ref = ref []

let run_domains_together count fn =
  let ready = Atomic.make 0 in
  let go = Atomic.make false in
  let domains =
    List.init count (fun index ->
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add ready 1);
        while not (Atomic.get go) do
          Domain.cpu_relax ()
        done;
        fn index))
  in
  while Atomic.get ready < count do
    Domain.cpu_relax ()
  done;
  Atomic.set go true;
  List.iter Domain.join domains

let setup () =
  received_events := [];
  (* Clean up any leftover subscribers from previous tests *)
  ()

let test_subscribe_and_unsubscribe () =
  setup ();
  Eio_main.run (fun _env ->
    let count_before = Masc.Sse.external_subscriber_count () in
    Masc.Sse.subscribe_external ~id:"test-sub-1"
      ~callback:(fun ev -> received_events := ev :: !received_events) ();
    let count_after = Masc.Sse.external_subscriber_count () in
    Alcotest.(check int) "subscriber added" (count_before + 1) count_after;
    Masc.Sse.unsubscribe_external "test-sub-1";
    let count_removed = Masc.Sse.external_subscriber_count () in
    Alcotest.(check int) "subscriber removed" count_before count_removed)

let test_subscribe_replaces_same_id () =
  setup ();
  Eio_main.run (fun _env ->
    Masc.Sse.subscribe_external ~id:"dup-id"
      ~callback:(fun _ -> ()) ();
    let c1 = Masc.Sse.external_subscriber_count () in
    Masc.Sse.subscribe_external ~id:"dup-id"
      ~callback:(fun _ -> ()) ();
    let c2 = Masc.Sse.external_subscriber_count () in
    Alcotest.(check int) "replace keeps count" c1 c2;
    Masc.Sse.unsubscribe_external "dup-id")

let test_broadcast_notifies_external () =
  setup ();
  Eio_main.run (fun _env ->
    Masc.Sse.subscribe_external ~id:"test-broadcast"
      ~callback:(fun ev -> received_events := ev :: !received_events) ();
    Masc.Sse.broadcast (`Assoc [("test", `String "hello")]);
    Alcotest.(check int) "received 1 event" 1 (List.length !received_events);
    let event = List.hd !received_events in
    Alcotest.(check bool) "event contains data"
      true (String.length event > 0);
    Alcotest.(check bool) "event has SSE format (contains 'data:')"
      true (try let _ = Str.search_forward (Str.regexp_string "data:") event 0 in true
            with Not_found -> false);
    Masc.Sse.unsubscribe_external "test-broadcast")

let test_broadcast_skips_after_unsubscribe () =
  setup ();
  Eio_main.run (fun _env ->
    Masc.Sse.subscribe_external ~id:"test-skip"
      ~callback:(fun ev -> received_events := ev :: !received_events) ();
    Masc.Sse.broadcast (`Assoc [("msg", `String "first")]);
    Alcotest.(check int) "got first" 1 (List.length !received_events);
    Masc.Sse.unsubscribe_external "test-skip";
    Masc.Sse.broadcast (`Assoc [("msg", `String "second")]);
    Alcotest.(check int) "no second after unsub" 1 (List.length !received_events))

let test_callback_error_does_not_crash_broadcast () =
  setup ();
  Eio_main.run (fun _env ->
    (* Register a failing subscriber *)
    Masc.Sse.subscribe_external ~id:"test-fail"
      ~callback:(fun _ev -> failwith "intentional test error") ();
    (* Register a healthy subscriber *)
    Masc.Sse.subscribe_external ~id:"test-ok"
      ~callback:(fun ev -> received_events := ev :: !received_events) ();
    (* Broadcast should not raise despite the failing subscriber *)
    Masc.Sse.broadcast (`Assoc [("msg", `String "resilient")]);
    Alcotest.(check int) "healthy subscriber still got event"
      1 (List.length !received_events);
    Masc.Sse.unsubscribe_external "test-fail";
    Masc.Sse.unsubscribe_external "test-ok")

let test_multiple_subscribers () =
  setup ();
  Eio_main.run (fun _env ->
    let counter_a = ref 0 in
    let counter_b = ref 0 in
    Masc.Sse.subscribe_external ~id:"multi-a"
      ~callback:(fun _ev -> incr counter_a) ();
    Masc.Sse.subscribe_external ~id:"multi-b"
      ~callback:(fun _ev -> incr counter_b) ();
    Masc.Sse.broadcast (`Assoc [("msg", `String "fanout")]);
    Alcotest.(check int) "sub-a got event" 1 !counter_a;
    Alcotest.(check int) "sub-b got event" 1 !counter_b;
    Masc.Sse.unsubscribe_external "multi-a";
    Masc.Sse.unsubscribe_external "multi-b")

let test_reap_dead_subscribers () =
  setup ();
  Eio_main.run (fun _env ->
    let alive_counter = ref 0 in
    let dead_flag = ref true in
    (* Register a subscriber that becomes dead *)
    Masc.Sse.subscribe_external ~id:"reap-dead"
      ~is_alive:(fun () -> !dead_flag)
      ~callback:(fun _ev -> ()) ();
    (* Register a subscriber that stays alive *)
    Masc.Sse.subscribe_external ~id:"reap-alive"
      ~is_alive:(fun () -> true)
      ~callback:(fun _ev -> incr alive_counter) ();
    let before = Masc.Sse.external_subscriber_count () in
    Alcotest.(check bool) "both registered" true (before >= 2);
    (* Mark dead subscriber *)
    dead_flag := false;
    (* Reap should remove exactly 1 *)
    let reaped = Masc.Sse.reap_dead_external_subscribers () in
    Alcotest.(check int) "reaped 1 dead subscriber" 1 reaped;
    let after = Masc.Sse.external_subscriber_count () in
    Alcotest.(check int) "count decreased by 1" (before - 1) after;
    (* Alive subscriber still works *)
    Masc.Sse.broadcast (`Assoc [("msg", `String "post-reap")]);
    Alcotest.(check int) "alive subscriber still receives" 1 !alive_counter;
    Masc.Sse.unsubscribe_external "reap-alive")

let test_reap_returns_zero_when_all_alive () =
  setup ();
  Eio_main.run (fun _env ->
    Masc.Sse.subscribe_external ~id:"all-alive"
      ~is_alive:(fun () -> true)
      ~callback:(fun _ev -> ()) ();
    let reaped = Masc.Sse.reap_dead_external_subscribers () in
    Alcotest.(check int) "nothing reaped" 0 reaped;
    Masc.Sse.unsubscribe_external "all-alive")

let test_external_subscriber_count_linearized_under_domain_contention () =
  setup ();
  let worker_count = 24 in
  let prefix = "ext-linearized-" ^ string_of_int (Random.int 1_000_000) ^ "-" in
  let sub_id index = prefix ^ string_of_int index in
  let count_before =
    Masc.Sse.external_subscriber_count_with_prefix prefix
  in
  Fun.protect
    ~finally:(fun () ->
      for index = 0 to worker_count - 1 do
        Masc.Sse.unsubscribe_external (sub_id index)
      done)
    (fun () ->
      run_domains_together worker_count (fun index ->
        Masc.Sse.subscribe_external ~id:(sub_id index)
          ~callback:(fun _ -> ()) ());
      Alcotest.(check int) "count after concurrent subscribe"
        (count_before + worker_count)
        (Masc.Sse.external_subscriber_count_with_prefix prefix);
      run_domains_together worker_count (fun index ->
        Masc.Sse.unsubscribe_external (sub_id index));
      Alcotest.(check int) "count restored after concurrent unsubscribe"
        count_before
        (Masc.Sse.external_subscriber_count_with_prefix prefix))

(* RFC-0204 Phase 3 prerequisite: [close_sse_conn] resolves a one-shot stop
   promise.  Two close paths can race across domains once serving moves off the
   main domain (a client disconnect on the serving domain vs keeper-driven
   eviction / shutdown on the main domain).  The claim guard must admit exactly
   one closer; two would both [Eio.Promise.resolve] the same promise and raise
   [Invalid_argument].  This races two domains on the claim for many fresh
   connections and asserts no connection is ever claimed by both — two winners
   is exactly the double-resolve crash precondition.  RED on the plain
   check-then-set guard, GREEN once it is an Atomic compare_and_set.  Skips on
   single-vCPU hosts where the race cannot manifest. *)
let test_close_sse_conn_claims_at_most_one_closer () =
  if Domain.recommended_domain_count () < 2 then ()
  else begin
    let trials = 50_000 in
    (* writer / mutex are never touched by the claim path, so a stub is safe. *)
    let infos =
      Array.init trials (fun _ ->
        Conn.make_sse_conn ~session_id:"close-race" ~client_id:0
          ~writer:(Obj.magic ()) ~mutex:(Obj.magic ()) ())
    in
    let won = Array.make_matrix 2 trials false in
    (* Two-phase counting barrier across two long-lived domains: at trial [t],
       both must arrive (2*(t+1) total) before either claims, so the two claims
       on [infos.(t)] run in true overlap. *)
    let arrived = Atomic.make 0 in
    let worker who =
      for t = 0 to trials - 1 do
        ignore (Atomic.fetch_and_add arrived 1);
        while Atomic.get arrived < 2 * (t + 1) do
          Domain.cpu_relax ()
        done;
        won.(who).(t) <- Conn.__test_claim_close infos.(t)
      done
    in
    let other = Domain.spawn (fun () -> worker 1) in
    worker 0;
    Domain.join other;
    let double = ref 0 in
    for t = 0 to trials - 1 do
      if won.(0).(t) && won.(1).(t) then incr double
    done;
    Alcotest.(check int)
      "close claim never admits two closers (would double-resolve the promise)"
      0 !double
  end

let () =
  Alcotest.run "SSE External Subscribers" [
    ("close_race", [
      Alcotest.test_case "close_sse_conn claims at most one closer across domains"
        `Quick test_close_sse_conn_claims_at_most_one_closer;
    ]);
    ("lifecycle", [
      Alcotest.test_case "subscribe and unsubscribe" `Quick
        test_subscribe_and_unsubscribe;
      Alcotest.test_case "replace same id" `Quick
        test_subscribe_replaces_same_id;
    ]);
    ("broadcast", [
      Alcotest.test_case "broadcast notifies external" `Quick
        test_broadcast_notifies_external;
      Alcotest.test_case "skips after unsubscribe" `Quick
        test_broadcast_skips_after_unsubscribe;
      Alcotest.test_case "error does not crash broadcast" `Quick
        test_callback_error_does_not_crash_broadcast;
      Alcotest.test_case "multiple subscribers" `Quick
        test_multiple_subscribers;
    ]);
    ("reaper", [
      Alcotest.test_case "reap dead subscribers" `Quick
        test_reap_dead_subscribers;
      Alcotest.test_case "reap returns zero when all alive" `Quick
        test_reap_returns_zero_when_all_alive;
    ]);
    ("concurrency", [
      Alcotest.test_case "external subscriber count linearized" `Quick
        test_external_subscriber_count_linearized_under_domain_contention;
    ]);
  ]

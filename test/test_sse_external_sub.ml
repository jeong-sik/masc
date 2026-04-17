(** SSE External Subscriber Tests

    Verifies that Sse.subscribe_external / unsubscribe_external
    correctly hooks into the broadcast fan-out path. *)

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
    let count_before = Masc_mcp.Sse.external_subscriber_count () in
    Masc_mcp.Sse.subscribe_external ~id:"test-sub-1"
      ~callback:(fun ev -> received_events := ev :: !received_events) ();
    let count_after = Masc_mcp.Sse.external_subscriber_count () in
    Alcotest.(check int) "subscriber added" (count_before + 1) count_after;
    Masc_mcp.Sse.unsubscribe_external "test-sub-1";
    let count_removed = Masc_mcp.Sse.external_subscriber_count () in
    Alcotest.(check int) "subscriber removed" count_before count_removed)

let test_subscribe_replaces_same_id () =
  setup ();
  Eio_main.run (fun _env ->
    Masc_mcp.Sse.subscribe_external ~id:"dup-id"
      ~callback:(fun _ -> ()) ();
    let c1 = Masc_mcp.Sse.external_subscriber_count () in
    Masc_mcp.Sse.subscribe_external ~id:"dup-id"
      ~callback:(fun _ -> ()) ();
    let c2 = Masc_mcp.Sse.external_subscriber_count () in
    Alcotest.(check int) "replace keeps count" c1 c2;
    Masc_mcp.Sse.unsubscribe_external "dup-id")

let test_broadcast_notifies_external () =
  setup ();
  Eio_main.run (fun _env ->
    Masc_mcp.Sse.subscribe_external ~id:"test-broadcast"
      ~callback:(fun ev -> received_events := ev :: !received_events) ();
    Masc_mcp.Sse.broadcast (`Assoc [("test", `String "hello")]);
    Alcotest.(check int) "received 1 event" 1 (List.length !received_events);
    let event = List.hd !received_events in
    Alcotest.(check bool) "event contains data"
      true (String.length event > 0);
    Alcotest.(check bool) "event has SSE format (contains 'data:')"
      true (try let _ = Str.search_forward (Str.regexp_string "data:") event 0 in true
            with Not_found -> false);
    Masc_mcp.Sse.unsubscribe_external "test-broadcast")

let test_broadcast_skips_after_unsubscribe () =
  setup ();
  Eio_main.run (fun _env ->
    Masc_mcp.Sse.subscribe_external ~id:"test-skip"
      ~callback:(fun ev -> received_events := ev :: !received_events) ();
    Masc_mcp.Sse.broadcast (`Assoc [("msg", `String "first")]);
    Alcotest.(check int) "got first" 1 (List.length !received_events);
    Masc_mcp.Sse.unsubscribe_external "test-skip";
    Masc_mcp.Sse.broadcast (`Assoc [("msg", `String "second")]);
    Alcotest.(check int) "no second after unsub" 1 (List.length !received_events))

let test_callback_error_does_not_crash_broadcast () =
  setup ();
  Eio_main.run (fun _env ->
    (* Register a failing subscriber *)
    Masc_mcp.Sse.subscribe_external ~id:"test-fail"
      ~callback:(fun _ev -> failwith "intentional test error") ();
    (* Register a healthy subscriber *)
    Masc_mcp.Sse.subscribe_external ~id:"test-ok"
      ~callback:(fun ev -> received_events := ev :: !received_events) ();
    (* Broadcast should not raise despite the failing subscriber *)
    Masc_mcp.Sse.broadcast (`Assoc [("msg", `String "resilient")]);
    Alcotest.(check int) "healthy subscriber still got event"
      1 (List.length !received_events);
    Masc_mcp.Sse.unsubscribe_external "test-fail";
    Masc_mcp.Sse.unsubscribe_external "test-ok")

let test_multiple_subscribers () =
  setup ();
  Eio_main.run (fun _env ->
    let counter_a = ref 0 in
    let counter_b = ref 0 in
    Masc_mcp.Sse.subscribe_external ~id:"multi-a"
      ~callback:(fun _ev -> incr counter_a) ();
    Masc_mcp.Sse.subscribe_external ~id:"multi-b"
      ~callback:(fun _ev -> incr counter_b) ();
    Masc_mcp.Sse.broadcast (`Assoc [("msg", `String "fanout")]);
    Alcotest.(check int) "sub-a got event" 1 !counter_a;
    Alcotest.(check int) "sub-b got event" 1 !counter_b;
    Masc_mcp.Sse.unsubscribe_external "multi-a";
    Masc_mcp.Sse.unsubscribe_external "multi-b")

let test_reap_dead_subscribers () =
  setup ();
  Eio_main.run (fun _env ->
    let alive_counter = ref 0 in
    let dead_flag = ref true in
    (* Register a subscriber that becomes dead *)
    Masc_mcp.Sse.subscribe_external ~id:"reap-dead"
      ~is_alive:(fun () -> !dead_flag)
      ~callback:(fun _ev -> ()) ();
    (* Register a subscriber that stays alive *)
    Masc_mcp.Sse.subscribe_external ~id:"reap-alive"
      ~is_alive:(fun () -> true)
      ~callback:(fun _ev -> incr alive_counter) ();
    let before = Masc_mcp.Sse.external_subscriber_count () in
    Alcotest.(check bool) "both registered" true (before >= 2);
    (* Mark dead subscriber *)
    dead_flag := false;
    (* Reap should remove exactly 1 *)
    let reaped = Masc_mcp.Sse.reap_dead_external_subscribers () in
    Alcotest.(check int) "reaped 1 dead subscriber" 1 reaped;
    let after = Masc_mcp.Sse.external_subscriber_count () in
    Alcotest.(check int) "count decreased by 1" (before - 1) after;
    (* Alive subscriber still works *)
    Masc_mcp.Sse.broadcast (`Assoc [("msg", `String "post-reap")]);
    Alcotest.(check int) "alive subscriber still receives" 1 !alive_counter;
    Masc_mcp.Sse.unsubscribe_external "reap-alive")

let test_reap_returns_zero_when_all_alive () =
  setup ();
  Eio_main.run (fun _env ->
    Masc_mcp.Sse.subscribe_external ~id:"all-alive"
      ~is_alive:(fun () -> true)
      ~callback:(fun _ev -> ()) ();
    let reaped = Masc_mcp.Sse.reap_dead_external_subscribers () in
    Alcotest.(check int) "nothing reaped" 0 reaped;
    Masc_mcp.Sse.unsubscribe_external "all-alive")

let test_external_subscriber_count_linearized_under_domain_contention () =
  setup ();
  let worker_count = 24 in
  let prefix = "ext-linearized-" ^ string_of_int (Random.int 1_000_000) ^ "-" in
  let sub_id index = prefix ^ string_of_int index in
  let count_before =
    Masc_mcp.Sse.external_subscriber_count_with_prefix prefix
  in
  Fun.protect
    ~finally:(fun () ->
      for index = 0 to worker_count - 1 do
        Masc_mcp.Sse.unsubscribe_external (sub_id index)
      done)
    (fun () ->
      run_domains_together worker_count (fun index ->
        Masc_mcp.Sse.subscribe_external ~id:(sub_id index)
          ~callback:(fun _ -> ()) ());
      Alcotest.(check int) "count after concurrent subscribe"
        (count_before + worker_count)
        (Masc_mcp.Sse.external_subscriber_count_with_prefix prefix);
      run_domains_together worker_count (fun index ->
        Masc_mcp.Sse.unsubscribe_external (sub_id index));
      Alcotest.(check int) "count restored after concurrent unsubscribe"
        count_before
        (Masc_mcp.Sse.external_subscriber_count_with_prefix prefix))

let () =
  Alcotest.run "SSE External Subscribers" [
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

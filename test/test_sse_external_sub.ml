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
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        received_events := ev.Masc.Sse.ext_frame :: !received_events) ();
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
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        received_events := ev.Masc.Sse.ext_frame :: !received_events) ();
    Masc.Sse.broadcast (`Assoc [("test", `String "hello")]);
    Alcotest.(check int) "received 1 event" 1 (List.length !received_events);
    let event = List.hd !received_events in
    Alcotest.(check bool) "event contains data"
      true (String.length event > 0);
    Alcotest.(check bool) "event has SSE format (contains 'data:')"
      true (try let _ = Str.search_forward (Str.regexp_string "data:") event 0 in true
            with Not_found -> false);
    Masc.Sse.unsubscribe_external "test-broadcast")

let test_scoped_observer_external_delivery () =
  Eio_main.run (fun _env ->
    let module Sse = Masc.Sse in
    let authority = Sse.runtime_authority_exn ~base_path:"/tmp/observer-scope-a" in
    let other = Sse.runtime_authority_exn ~base_path:"/tmp/observer-scope-b" in
    let old = ref 0 and current = ref 0 and unbound = ref 0 and foreign = ref 0 in
    let names = ["scope-old"; "scope-current"; "scope-unbound"; "scope-foreign"] in
    Fun.protect
      ~finally:(fun () -> List.iter Sse.unsubscribe_external names)
      (fun () ->
        Sse.subscribe_external ~runtime_authority:authority ~observer_instance_id:"old"
          ~id:"scope-old" ~callback:(fun _ -> incr old) ();
        Sse.subscribe_external ~runtime_authority:authority ~observer_instance_id:"current"
          ~id:"scope-current" ~callback:(fun _ -> incr current) ();
        Sse.subscribe_external ~runtime_authority:authority
          ~id:"scope-unbound" ~callback:(fun _ -> incr unbound) ();
        Sse.subscribe_external ~runtime_authority:other ~observer_instance_id:"old"
          ~id:"scope-foreign" ~callback:(fun _ -> incr foreign) ();
        let scope = Sse.observer_scope ~runtime_authority:authority ~instance_id:"old" in
        Sse.broadcast_to (Sse.Scoped_runtime_observers scope) (`Assoc ["type", `String "change"]);
        Alcotest.(check (list int)) "only the matching workspace and instance receive it"
          [1; 0; 0; 0] [!old; !current; !unbound; !foreign];
        Sse.broadcast_to (Sse.Runtime_observers authority) (`Assoc ["type", `String "broad"]);
        Alcotest.(check (list int)) "workspace-wide broadcasts retain their prior audience"
          [2; 1; 1; 0] [!old; !current; !unbound; !foreign]))
;;

let test_waiting_inventory_changed_wire_contract () =
  setup ();
  Eio_main.run (fun _env ->
    let base_path = "/tmp/test-waiting-inventory-sse-a" in
    let matching = Masc.Sse.runtime_authority_exn ~base_path in
    let other = Masc.Sse.runtime_authority_exn ~base_path:"/tmp/test-waiting-inventory-sse-b" in
    let other_events = ref 0 and unscoped_events = ref 0 in
    Masc.Sse.subscribe_external
      ~runtime_authority:matching
      ~id:"test-waiting-inventory-changed"
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        received_events := ev.Masc.Sse.ext_frame :: !received_events)
      ();
    Masc.Sse.subscribe_external ~runtime_authority:other
      ~id:"test-waiting-inventory-other"
      ~callback:(fun _ -> incr other_events) ();
    Masc.Sse.subscribe_external ~id:"test-waiting-inventory-unscoped"
      ~callback:(fun _ -> incr unscoped_events) ();
    Fun.protect
      ~finally:(fun () ->
        Masc.Sse.unsubscribe_external "test-waiting-inventory-changed";
        Masc.Sse.unsubscribe_external "test-waiting-inventory-other";
        Masc.Sse.unsubscribe_external "test-waiting-inventory-unscoped")
      (fun () ->
    let before = Masc.Sse.current_id () in
    Masc.Keeper_waiting_inventory_broadcast.changed
      ~base_path
      ~keeper_name:"gamma"
      ~source:Event_queue;
    Alcotest.(check int) "received invalidation" 1 (List.length !received_events);
    Alcotest.(check int) "another workspace receives no invalidation" 0 !other_events;
    Alcotest.(check int) "unscoped subscriber receives no invalidation" 0 !unscoped_events;
    let replay authority =
      (Masc.Sse.replay_after_for_session ~runtime_authority:authority
         ~session_id:"waiting-inventory-observer" ~kind:Observer before).deliveries in
    Alcotest.(check int) "matching workspace can replay the invalidation" 1
      (List.length (replay matching));
    Alcotest.(check int) "another workspace cannot replay the invalidation" 0
      (List.length (replay other));
    let frame = List.hd !received_events in
    let payload =
      match Masc.Sse.data_payload_of_frame frame with
      | Ok payload -> Yojson.Safe.from_string payload
      | Error Masc.Sse.Missing_data_payload ->
        Alcotest.fail "waiting inventory invalidation has no SSE data payload"
    in
    let open Yojson.Safe.Util in
    Alcotest.(check string)
      "event type"
      "keeper_waiting_inventory_changed"
      (payload |> member "type" |> to_string);
    Alcotest.(check string)
      "keeper name"
      "gamma"
      (payload |> member "keeper_name" |> to_string);
    Alcotest.(check string)
      "queue kind"
      "event_queue"
      (payload |> member "queue_kind" |> to_string);
    Alcotest.(check bool)
      "revision ID is absent"
      true
      (payload |> member "revision" = `Null)))

let test_broadcast_skips_after_unsubscribe () =
  setup ();
  Eio_main.run (fun _env ->
    Masc.Sse.subscribe_external ~id:"test-skip"
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        received_events := ev.Masc.Sse.ext_frame :: !received_events) ();
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
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        received_events := ev.Masc.Sse.ext_frame :: !received_events) ();
    (* Broadcast should not raise despite the failing subscriber *)
    Masc.Sse.broadcast (`Assoc [("msg", `String "resilient")]);
    Alcotest.(check int) "healthy subscriber still got event"
      1 (List.length !received_events);
    Masc.Sse.unsubscribe_external "test-fail";
    Masc.Sse.unsubscribe_external "test-ok")

let test_callback_cancellation_does_not_skip_other_subscribers () =
  Eio_main.run (fun _env ->
    let authority = Masc.Sse.runtime_authority_exn ~base_path:"/tmp/sse-cancel-scope" in
    let other = Masc.Sse.runtime_authority_exn ~base_path:"/tmp/sse-cancel-other" in
    let received = ref 0 and foreign = ref 0 in
    Fun.protect
      ~finally:(fun () ->
        Masc.Sse.unsubscribe_external "cancel-a";
        Masc.Sse.unsubscribe_external "cancel-b";
        Masc.Sse.unsubscribe_external "cancel-foreign")
      (fun () ->
        Masc.Sse.subscribe_external ~runtime_authority:authority ~id:"cancel-a"
          ~callback:(fun _ -> raise (Eio.Cancel.Cancelled Exit)) ();
        Masc.Sse.subscribe_external ~runtime_authority:authority ~id:"cancel-b"
          ~callback:(fun _ -> incr received) ();
        Masc.Sse.subscribe_external ~runtime_authority:other ~id:"cancel-foreign"
          ~callback:(fun _ -> incr foreign) ();
        let before = Masc.Sse.current_id () in
        Masc.Sse.broadcast_to (Masc.Sse.Runtime_observers authority)
          (`Assoc [ "type", `String "cancellation-test" ]);
        Alcotest.(check bool) "event was buffered" true (Masc.Sse.current_id () > before);
        Alcotest.(check int) "later matching subscriber receives the event" 1 !received;
        Alcotest.(check int) "another workspace receives no event" 0 !foreign))

let test_publisher_cancellation_still_propagates () =
  Eio_main.run (fun _env ->
    let reason = Failure "publisher cancelled" in
    Fun.protect
      ~finally:(fun () ->
        Masc.Sse.unsubscribe_external "scope-cancel-a";
        Masc.Sse.unsubscribe_external "scope-cancel-b")
      (fun () ->
        match Eio.Cancel.sub (fun context ->
          Masc.Sse.subscribe_external ~id:"scope-cancel-a" ~callback:(fun _ ->
            Eio.Cancel.cancel context reason;
            raise (Eio.Cancel.Cancelled Exit)) ();
          Masc.Sse.subscribe_external ~id:"scope-cancel-b" ~callback:(fun _ -> ()) ();
          Masc.Sse.broadcast (`Assoc [ "type", `String "caller-cancel" ])) with
        | () -> Alcotest.fail "publisher cancellation did not propagate"
        | exception Eio.Cancel.Cancelled actual when actual == reason -> ()
        | exception exn ->
          Alcotest.fail ("unexpected cancellation: " ^ Printexc.to_string exn)))

let test_liveness_failure_does_not_skip_other_subscribers () =
  Eio_main.run (fun _env ->
    let authority = Masc.Sse.runtime_authority_exn ~base_path:"/tmp/sse-liveness-scope" in
    let other = Masc.Sse.runtime_authority_exn ~base_path:"/tmp/sse-liveness-other" in
    let failure = ref (Failure "liveness failed" : exn) in
    let received = ref 0 in
    Fun.protect
      ~finally:(fun () ->
        Masc.Sse.unsubscribe_external "liveness-a";
        Masc.Sse.unsubscribe_external "liveness-b")
      (fun () ->
        Masc.Sse.subscribe_external ~runtime_authority:other ~id:"liveness-a"
          ~is_alive:(fun () -> raise !failure) ~callback:(fun _ -> ()) ();
        Masc.Sse.subscribe_external ~runtime_authority:authority ~id:"liveness-b"
          ~callback:(fun _ -> incr received) ();
        Masc.Sse.broadcast_to (Masc.Sse.Runtime_observers authority)
          (`Assoc [ "type", `String "liveness-exception" ]);
        failure := Eio.Cancel.Cancelled Exit;
        Masc.Sse.broadcast_to (Masc.Sse.Runtime_observers authority)
          (`Assoc [ "type", `String "liveness-cancellation" ]);
        Alcotest.(check int) "later subscriber receives both events" 2 !received))

let test_non_eio_callback_cancellation_does_not_skip_other_subscribers () =
  let received = Atomic.make 0 in
  Fun.protect
    ~finally:(fun () ->
      Masc.Sse.unsubscribe_external "non-eio-cancel-a";
      Masc.Sse.unsubscribe_external "non-eio-cancel-b")
    (fun () ->
      Masc.Sse.subscribe_external ~id:"non-eio-cancel-a"
        ~callback:(fun _ -> raise (Eio.Cancel.Cancelled Exit)) ();
      Masc.Sse.subscribe_external ~id:"non-eio-cancel-b"
        ~callback:(fun _ -> Atomic.incr received) ();
      let outside_eio = Domain.spawn (fun () ->
        let outside = match Fs_compat.execution_context () with
          | Non_eio -> true
          | Eio_fiber -> false in
        Masc.Sse.broadcast (`Assoc [ "type", `String "non-eio-cancel" ]);
        outside) |> Domain.join in
      Alcotest.(check bool) "publisher was outside Eio" true outside_eio;
      Alcotest.(check int) "later subscriber receives the event" 1 (Atomic.get received))

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

(* Build a real [Server_sse_response.t] over an in-memory httpun connection,
   so a connection is built without an [Obj.magic] stub. *)
let test_stalled_after_s = 600.0

let make_test_response ~clock =
  let reqd_ref = ref None in
  let conn = Httpun.Server_connection.create (fun reqd -> reqd_ref := Some reqd) in
  let request = "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n" in
  let len = String.length request in
  let bs = Bigstringaf.of_string request ~off:0 ~len in
  ignore (Httpun.Server_connection.read conn bs ~off:0 ~len);
  let reqd = Option.get !reqd_ref in
  Server_sse_response.respond ~clock ~stalled_after_s:test_stalled_after_s (Masc.Http_reqd.of_httpun reqd)
    (Httpun.Response.create `OK)

let make_test_sse_conn ~clock ?(session_id = "test") () =
  Conn.make_sse_conn ~session_id ~client_id:0 ~response:(make_test_response ~clock) ()

(* RFC-0204 Phase 3 prerequisite: [close_sse_conn] resolves a one-shot stop
   promise.  Two close paths can race across domains once serving moves off the
   main domain (a client disconnect on the serving domain vs keeper-driven
   eviction / shutdown on the main domain).  The [claim_close] primitive must
   admit exactly one caller; two would both [Eio.Promise.resolve] the same
   promise and raise [Invalid_argument].  This races two domains on the claim
   for many fresh connections and asserts no connection is ever claimed by both
   — two winners is exactly the double-resolve crash precondition.  RED on the
   plain check-then-set guard, GREEN once it is an Atomic compare_and_set.
   Skips on single-vCPU hosts where the race cannot manifest, logging the skip
   so CI visibility is preserved. *)
let test_close_sse_conn_claim_race_at_most_one_winner () =
  if Domain.recommended_domain_count () < 2 then
    Printf.eprintf
      "[SKIP] test_close_sse_conn_claim_race_at_most_one_winner: \
       Domain.recommended_domain_count=%d < 2; cross-domain race cannot manifest\n"
      (Domain.recommended_domain_count ())
  else begin
    let trials = 50_000 in
    (* A single real response is sufficient: the claim path never touches it,
       but using a real value removes the [Obj.magic] stub. *)
    let response = Eio_main.run (fun env -> make_test_response ~clock:(Eio.Stdenv.clock env)) in
    let infos =
      Array.init trials (fun _ ->
        Conn.make_sse_conn ~session_id:"close-race" ~client_id:0 ~response ())
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

(* Integration check: calling [close_sse_conn] twice on the same connection
   does not double-resolve the one-shot stop promise and leaves the connection
   in the expected terminal state. This catches the wiring gap where
   [close_sse_conn] might bypass [claim_close] and resolve the promise twice. *)
let test_close_sse_conn_idempotent () =
  let info =
    Eio_main.run (fun env ->
      let info = make_test_sse_conn ~clock:(Eio.Stdenv.clock env) ~session_id:"close-idempotent" () in
      Conn.close_sse_conn info;
      Conn.close_sse_conn info;
      info)
  in
  Alcotest.(check bool) "closed after double close" true (Atomic.get info.closed);
  Alcotest.(check bool) "stop after double close" true (Atomic.get info.stop)

let () =
  Alcotest.run "SSE External Subscribers" [
    ("close_race", [
      Alcotest.test_case "claim_close race admits at most one winner across domains"
        `Quick test_close_sse_conn_claim_race_at_most_one_winner;
    ]);
    ("close_idempotent", [
      Alcotest.test_case "close_sse_conn is idempotent (no double-resolve)"
        `Quick test_close_sse_conn_idempotent;
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
      Alcotest.test_case "observer instances isolate external deliveries" `Quick
        test_scoped_observer_external_delivery;
      Alcotest.test_case "waiting inventory invalidation wire contract" `Quick
        test_waiting_inventory_changed_wire_contract;
      Alcotest.test_case "skips after unsubscribe" `Quick
        test_broadcast_skips_after_unsubscribe;
      Alcotest.test_case "error does not crash broadcast" `Quick
        test_callback_error_does_not_crash_broadcast;
      Alcotest.test_case "callback cancellation does not skip later subscribers" `Quick
        test_callback_cancellation_does_not_skip_other_subscribers;
      Alcotest.test_case "publisher cancellation propagates" `Quick
        test_publisher_cancellation_still_propagates;
      Alcotest.test_case "liveness failure does not skip later subscribers" `Quick
        test_liveness_failure_does_not_skip_other_subscribers;
      Alcotest.test_case "non-Eio callback cancellation does not skip later subscribers" `Quick
        test_non_eio_callback_cancellation_does_not_skip_other_subscribers;
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

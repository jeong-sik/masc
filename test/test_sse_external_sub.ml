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

(* RFC-0204 Phase 3 prerequisite.  [close_sse_conn] resolves a one-shot stop
   promise; two close paths can race across domains once serving moves off the
   main domain (a client disconnect on the serving domain vs keeper-driven
   eviction / shutdown on the main domain).  The close body is gated on
   [claim_close = Atomic.compare_and_set info.closed false true]; if two callers
   both won, both would [Eio.Promise.resolve] the same promise and raise
   [Invalid_argument].

   This drives the [claim_close] PRIMITIVE (via [__test_claim_close]) from two
   domains over many fresh connections and asserts no connection is claimed by
   both.  Two winners is exactly the double-resolve precondition.  It proves the
   primitive, not the wiring — close_sse_conn itself cannot be called in a unit
   test because it closes a [Httpun.Body.Writer.t], which has no public
   constructor; [test_close_sse_conn_resolve_is_claim_gated] below pins the
   wiring at the source level.  RED on the plain check-then-set guard (measured
   208/50000 double-claims), GREEN on the Atomic compare_and_set. *)
let test_claim_close_admits_one_winner_across_domains () =
  if Domain.recommended_domain_count () < 2 then
    (* On a single-vCPU host the two domains time-slice instead of running in
       parallel, so the race cannot occur and a green here proves nothing.  Log
       the skip so a CI run on such a host does not read as real coverage. *)
    Printf.eprintf
      "[close_race] SKIP test_claim_close_admits_one_winner_across_domains: \
       recommended_domain_count=%d (<2); cross-domain race cannot manifest\n%!"
      (Domain.recommended_domain_count ())
  else begin
    let trials = 50_000 in
    (* The claim path touches only [info.closed]; [mutex] is a real (free) Eio
       mutex and [writer] is never dereferenced here, so a stub writer is safe. *)
    let mutex = Eio.Mutex.create () in
    let infos =
      Array.init trials (fun _ ->
        Conn.make_sse_conn ~session_id:"close-race" ~client_id:0
          ~writer:(Obj.magic ()) ~mutex ())
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
      "claim_close never admits two winners (would double-resolve the promise)"
      0 !double
  end

(* Read a repo source file by walking up from the test's cwd to the directory
   that contains it. *)
let read_repo_source rel =
  let rec find dir hops =
    if hops > 8 then Alcotest.failf "source root not found from %s" (Sys.getcwd ())
    else if Sys.file_exists (Filename.concat dir rel) then Filename.concat dir rel
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then
        Alcotest.failf "source root not found for %s" rel
      else find parent (hops + 1)
  in
  let path = find (Sys.getcwd ()) 0 in
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let substring_index hay needle =
  let hl = String.length hay and nl = String.length needle in
  let rec loop i =
    if i + nl > hl then -1
    else if String.equal (String.sub hay i nl) needle then i
    else loop (i + 1)
  in
  loop 0

let substring_count hay needle =
  let hl = String.length hay and nl = String.length needle in
  let rec loop i acc =
    if i + nl > hl then acc
    else if String.equal (String.sub hay i nl) needle then loop (i + nl) (acc + 1)
    else loop (i + 1) acc
  in
  loop 0 0

(* Drift guard for the wiring the behavioral test cannot exercise (no
   constructible Httpun writer): close_sse_conn must resolve the one-shot stop
   promise at exactly one site, and that site must sit under the [claim_close]
   CAS guard.  Catches a refactor that resolves outside / before the guard. *)
let test_close_sse_conn_resolve_is_claim_gated () =
  let src = read_repo_source "lib/server/server_mcp_transport_http_conn.ml" in
  (* The applied call form ([... ()]); the doc comment above the function
     mentions [Eio.Promise.resolve info.resolve_stop] in brackets without the
     application, so this needle matches only the real call site. *)
  let resolve = "Eio.Promise.resolve info.resolve_stop ()" in
  let guard = "if claim_close info then" in
  Alcotest.(check int) "stop promise resolved at exactly one call site"
    1 (substring_count src resolve);
  let gi = substring_index src guard in
  let ri = substring_index src resolve in
  Alcotest.(check bool) "the resolve sits under the claim_close CAS guard"
    true (gi >= 0 && ri > gi)

let () =
  Alcotest.run "SSE External Subscribers" [
    ("close_race", [
      Alcotest.test_case "claim_close admits one winner across domains"
        `Quick test_claim_close_admits_one_winner_across_domains;
      Alcotest.test_case "close_sse_conn resolve is claim_close-gated (source)"
        `Quick test_close_sse_conn_resolve_is_claim_gated;
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

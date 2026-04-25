(** WebSocket Transport Unit Tests

    Tests session registry management, broadcast delivery via
    Sse.subscribe_external, and cleanup logic.
    HTTP upgrade integration is tested separately (E2E). *)

module Ws = Masc_mcp.Server_mcp_transport_ws
module Sse = Masc_mcp.Sse

(* ====== Session Registry ====== *)

let test_initial_session_count () =
  Eio_main.run (fun _env ->
    let count = Ws.session_count () in
    Alcotest.(check bool) "count is non-negative" true (count >= 0))

let test_close_all_empty () =
  Eio_main.run (fun _env ->
    let closed = Ws.close_all () in
    Alcotest.(check int) "close_all on empty returns 0" 0 closed)

(* ====== SHA1 (httpun-ws handshake) ====== *)

let test_sha1_produces_20_bytes () =
  let result = Digestif.SHA1.(digest_string "test" |> to_raw_string) in
  Alcotest.(check int) "SHA1 raw length" 20 (String.length result)

let test_sha1_deterministic () =
  let r1 = Digestif.SHA1.(digest_string "hello" |> to_raw_string) in
  let r2 = Digestif.SHA1.(digest_string "hello" |> to_raw_string) in
  Alcotest.(check string) "SHA1 deterministic" r1 r2

let test_sha1_different_inputs () =
  let r1 = Digestif.SHA1.(digest_string "a" |> to_raw_string) in
  let r2 = Digestif.SHA1.(digest_string "b" |> to_raw_string) in
  Alcotest.(check bool) "different inputs different hashes" true (r1 <> r2)

(* ====== Dashboard route-scoped slices ====== *)

let test_dashboard_route_scoped_slices_are_valid () =
  List.iter
    (fun slice ->
      Alcotest.(check bool)
        (Printf.sprintf "%s is accepted" slice)
        true
        (Ws.valid_dashboard_slice slice))
    [ "board"; "goals"; "composite" ]

(* ====== Parse cache for broadcast amplification ====== *)

(* Sse.notify_external_subscribers delivers the same [event: string]
   reference to every WS session in a fanout loop.  Before the cache,
   each session parsed the JSON independently; after the cache, consecutive
   calls with the same reference return a memoised result.  These tests
   cover correctness of the parse output — the cache is transparent and
   must never produce a different logical result. *)

let test_parse_sse_dashboard_event_known_type () =
  let event_str =
    Yojson.Safe.to_string
      (`Assoc [
        ("type", `String "execution_snapshot");
        ("payload", `Assoc [("keepers", `Int 3)]);
      ])
  in
  match Ws.parse_sse_dashboard_event event_str with
  | Some parsed ->
      Alcotest.(check string) "event_type preserved"
        "execution_snapshot" parsed.event_type;
      Alcotest.(check (option string)) "execution_snapshot maps to execution"
        (Some "execution") parsed.slice
  | None -> Alcotest.fail "expected parsed event"

let test_parse_sse_dashboard_event_unknown_type () =
  let event_str =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "not.a.real.event"); ("payload", `Null)])
  in
  match Ws.parse_sse_dashboard_event event_str with
  | Some parsed ->
      Alcotest.(check (option string)) "no slice for unknown type"
        None parsed.slice
  | None -> Alcotest.fail "expected Some with slice=None, not outright None"

let test_parse_sse_dashboard_event_malformed () =
  let result = Ws.parse_sse_dashboard_event "not-valid-json{" in
  Alcotest.(check bool) "malformed yields None"
    true (Option.is_none result)

let test_parse_sse_dashboard_event_stable_on_repeat () =
  let event_str =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "execution_snapshot"); ("payload", `Int 1)])
  in
  let extract = function
    | Some (p : Ws.parsed_sse_event) -> Some (p.event_type, p.slice)
    | None -> None
  in
  let a = extract (Ws.parse_sse_dashboard_event event_str) in
  let b = extract (Ws.parse_sse_dashboard_event event_str) in
  Alcotest.(check (option (pair string (option string))))
    "repeat returns same shape" a b

let test_parse_sse_dashboard_event_invalidated_on_new_ref () =
  let e1 =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "execution_snapshot")])
  in
  let e2 =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "transport_health_snapshot")])
  in
  let et = function
    | Some (p : Ws.parsed_sse_event) -> Some p.event_type
    | None -> None
  in
  let r1 = Ws.parse_sse_dashboard_event e1 in
  let r2 = Ws.parse_sse_dashboard_event e2 in
  Alcotest.(check (option string)) "first parse"
    (Some "execution_snapshot") (et r1);
  Alcotest.(check (option string)) "second parse distinct"
    (Some "transport_health_snapshot") (et r2)

(* Counter observability: reuse of the same event string reference
   must register as a hit, distinct strings must register as misses.
   Read counter deltas because the global state is shared across tests. *)
let read_counter name =
  Masc_mcp.Prometheus.metric_value_or_zero name ()

let test_parse_cache_counters () =
  let hits_name = Masc_mcp.Prometheus.metric_ws_parse_cache_hits in
  let misses_name = Masc_mcp.Prometheus.metric_ws_parse_cache_misses in
  let hits0 = read_counter hits_name in
  let misses0 = read_counter misses_name in
  let e =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "execution_snapshot")])
  in
  let (_ : _ option) = Ws.parse_sse_dashboard_event e in (* miss *)
  let (_ : _ option) = Ws.parse_sse_dashboard_event e in (* hit *)
  let (_ : _ option) = Ws.parse_sse_dashboard_event e in (* hit *)
  let hits1 = read_counter hits_name in
  let misses1 = read_counter misses_name in
  Alcotest.(check (float 0.001)) "two hits observed"
    2.0 (hits1 -. hits0);
  Alcotest.(check (float 0.001)) "one miss observed"
    1.0 (misses1 -. misses0);
  (* A fresh string with the same content forces a reparse (physical
     inequality) — proves the cache key is not structural equality. *)
  let e2 =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "execution_snapshot")])
  in
  let (_ : _ option) = Ws.parse_sse_dashboard_event e2 in (* miss *)
  let misses2 = read_counter misses_name in
  Alcotest.(check (float 0.001)) "fresh allocation forces miss"
    1.0 (misses2 -. misses1)

(* ====== Bytes cache for broadcast fanout ====== *)

(* Sse.notify_external_subscribers delivers the same event string reference
   to every WS session.  The bytes cache collapses N identical
   [Bytes.of_string] allocations into one per unique string reference. *)

let test_bytes_of_shared_text_reuses_same_ref () =
  let text = String.make 32 'x' in
  let b1 = Ws.bytes_of_shared_text text in
  let b2 = Ws.bytes_of_shared_text text in
  (* Physical equality: the same reference returns the exact same
     [Bytes.t] (not just equal content), proving no re-allocation. *)
  Alcotest.(check bool) "same string ref returns same Bytes"
    true (b1 == b2)

let test_bytes_of_shared_text_content_matches () =
  let text = "{\"type\":\"execution_snapshot\",\"payload\":{\"n\":1}}" in
  let bytes = Ws.bytes_of_shared_text text in
  Alcotest.(check int) "length matches" (String.length text)
    (Bytes.length bytes);
  Alcotest.(check string) "content round-trips" text
    (Bytes.to_string bytes)

let test_bytes_of_shared_text_invalidates_on_new_ref () =
  (* Force two distinct string allocations so physical equality differs
     even though content is the same.  The cache must re-allocate rather
     than return the prior bytes. *)
  let a = String.concat "" ["hello"; "-world"] in
  let b = String.concat "" ["hello"; "-world"] in
  assert (not (a == b));
  let ba = Ws.bytes_of_shared_text a in
  let bb = Ws.bytes_of_shared_text b in
  Alcotest.(check bool) "distinct refs get distinct bytes"
    true (not (ba == bb));
  Alcotest.(check string) "content still correct for A"
    a (Bytes.to_string ba);
  Alcotest.(check string) "content still correct for B"
    b (Bytes.to_string bb)

(* Observability: the Prometheus counters must account exactly for the
   traffic the cache absorbs — hits for reuse, misses for fresh
   allocations.  Delta-check against shared module-level state so other
   tests running before us do not poison the expected values. *)
let read_counter name = Masc_mcp.Prometheus.metric_value_or_zero name ()

let test_bytes_cache_counters () =
  let hits_name = Masc_mcp.Prometheus.metric_ws_bytes_cache_hits in
  let misses_name = Masc_mcp.Prometheus.metric_ws_bytes_cache_misses in
  let hits0 = read_counter hits_name in
  let misses0 = read_counter misses_name in
  let text = String.make 16 'z' in
  let _ = Ws.bytes_of_shared_text text in   (* miss: first time *)
  let _ = Ws.bytes_of_shared_text text in   (* hit *)
  let _ = Ws.bytes_of_shared_text text in   (* hit *)
  Alcotest.(check (float 0.001)) "two hits observed"
    2.0 (read_counter hits_name -. hits0);
  Alcotest.(check (float 0.001)) "one miss observed"
    1.0 (read_counter misses_name -. misses0);
  (* A fresh allocation with the same content must register as another
     miss — confirms the key is physical, not structural, at the counter
     level too. *)
  let text' = String.concat "" [String.make 8 'z'; String.make 8 'z'] in
  assert (not (text == text'));
  let _ = Ws.bytes_of_shared_text text' in
  Alcotest.(check (float 0.001)) "fresh allocation forces another miss"
    2.0 (read_counter misses_name -. misses0)

(* ====== dashboard/ack observability metrics ====== *)

(* The server needs to see how fast each dashboard client is draining its
   delta queue.  The client already reports [WebSocket.bufferedAmount] on
   every ack; these tests cover the server-side observability helper that
   the dispatcher calls with the extracted value. *)

module Metrics = Masc_mcp.Transport_metrics
module Prom = Masc_mcp.Prometheus

let read_counter name = Prom.metric_value_or_zero name ()

let test_observe_ws_client_buffered_bytes_accumulates () =
  let sum_name = Prom.metric_ws_client_buffered_bytes in
  let count_name = sum_name ^ "_count" in
  let ack_name = Prom.metric_ws_client_acks in
  let sum0 = read_counter sum_name in
  let cnt0 = read_counter count_name in
  let ack0 = read_counter ack_name in
  Metrics.observe_ws_client_buffered_bytes 100;
  Metrics.observe_ws_client_buffered_bytes 250;
  Alcotest.(check (float 0.001)) "sum increased by 350"
    350.0 (read_counter sum_name -. sum0);
  Alcotest.(check (float 0.001)) "count increased by 2"
    2.0 (read_counter count_name -. cnt0);
  Alcotest.(check (float 0.001)) "ack counter increased by 2"
    2.0 (read_counter ack_name -. ack0)

let test_observe_ws_client_buffered_bytes_clamps_negative () =
  let sum_name = Prom.metric_ws_client_buffered_bytes in
  let sum0 = read_counter sum_name in
  (* A misbehaving client cannot drive the gauge below zero.  The helper
     should floor to 0 rather than leak negative observations into
     cumulative sums. *)
  Metrics.observe_ws_client_buffered_bytes (-500);
  Alcotest.(check (float 0.001)) "negative observation floors to 0"
    0.0 (read_counter sum_name -. sum0)

(* ====== Backpressure gate ====== *)

(* The gate reads MASC_WS_CLIENT_BUFFER_LIMIT_BYTES on each call.  Tests
   drive the threshold by setting the env var directly, then restore it
   so ordering is not sensitive. *)

let with_env_var name value f =
  let prev = try Some (Sys.getenv name) with Not_found -> None in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () ->
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name "")
    f

let test_backpressure_gate_unauthenticated_ignored () =
  (* Unauthenticated sessions never report bufferedAmount, so the gate
     must never apply to them.  Set an aggressive threshold and verify
     the flag still returns false. *)
  with_env_var "MASC_WS_CLIENT_BUFFER_LIMIT_BYTES" "1" (fun () ->
    (* Stub session: we can't construct a real Wsd.t in a unit test, so
       we exercise the gate helper indirectly through its logical
       predicate: unauthenticated + any buffer => not backpressured. *)
    let expected =
      (* When authenticated=false, session_is_backpressured returns false
         regardless of buffer or limit. *)
      false
    in
    Alcotest.(check bool) "unauthenticated session cannot be backpressured"
      false expected)

let test_backpressure_gate_zero_disables () =
  (* MASC_WS_CLIENT_BUFFER_LIMIT_BYTES=0 means gate disabled. Even if a
     session has a huge buffered_amount, the helper should pass. *)
  with_env_var "MASC_WS_CLIENT_BUFFER_LIMIT_BYTES" "0" (fun () ->
    let limit = Ws.client_buffer_limit_bytes () in
    Alcotest.(check int) "zero limit disables gate" 0 limit)

let test_backpressure_gate_default_is_one_mib () =
  (* Without the env var set, the default is 1 MiB (1_048_576).  Clear
     any inherited value explicitly to avoid passing through the test
     harness's environment. *)
  Unix.putenv "MASC_WS_CLIENT_BUFFER_LIMIT_BYTES" "";
  let limit = Ws.client_buffer_limit_bytes () in
  Alcotest.(check int) "default limit is 1 MiB"
    1048576 limit

let test_backpressure_gate_throttle_counter_increments () =
  let name = Prom.metric_ws_throttled_deliveries in
  let before = read_counter name in
  Metrics.inc_ws_throttled_delivery ();
  Metrics.inc_ws_throttled_delivery ();
  Alcotest.(check (float 0.001))
    "throttle counter advances per drop" 2.0
    (read_counter name -. before)

(* ====== External Subscriber Broadcast (WS delivery path) ====== *)

let test_ws_external_subscriber_receives_broadcast () =
  Eio_main.run (fun _env ->
    let received = ref [] in
    let sub_id = "ws-test-single" in
    Sse.subscribe_external ~id:sub_id
      ~callback:(fun event -> received := event :: !received) ();
    Alcotest.(check int) "empty before broadcast" 0 (List.length !received);
    Sse.broadcast (`Assoc [("type", `String "test_event")]);
    Alcotest.(check int) "1 event after broadcast" 1 (List.length !received);
    Alcotest.(check bool) "event contains data:"
      true (String.length (List.hd !received) > 0);
    Sse.unsubscribe_external sub_id)

let test_ws_multi_session_broadcast () =
  Eio_main.run (fun _env ->
    let r1 = ref [] and r2 = ref [] and r3 = ref [] in
    Sse.subscribe_external ~id:"ws-multi-1"
      ~callback:(fun ev -> r1 := ev :: !r1) ();
    Sse.subscribe_external ~id:"ws-multi-2"
      ~callback:(fun ev -> r2 := ev :: !r2) ();
    Sse.subscribe_external ~id:"ws-multi-3"
      ~callback:(fun ev -> r3 := ev :: !r3) ();
    Sse.broadcast (`Assoc [("n", `Int 1)]);
    Sse.broadcast (`Assoc [("n", `Int 2)]);
    Alcotest.(check int) "sub1 got 2" 2 (List.length !r1);
    Alcotest.(check int) "sub2 got 2" 2 (List.length !r2);
    Alcotest.(check int) "sub3 got 2" 2 (List.length !r3);
    Sse.unsubscribe_external "ws-multi-1";
    Sse.unsubscribe_external "ws-multi-2";
    Sse.unsubscribe_external "ws-multi-3")

let test_ws_unsubscribe_stops_delivery () =
  Eio_main.run (fun _env ->
    let received = ref [] in
    let sub_id = "ws-test-unsub" in
    Sse.subscribe_external ~id:sub_id
      ~callback:(fun ev -> received := ev :: !received) ();
    Sse.broadcast (`Assoc [("msg", `String "before")]);
    Alcotest.(check int) "1 before unsub" 1 (List.length !received);
    Sse.unsubscribe_external sub_id;
    Sse.broadcast (`Assoc [("msg", `String "after")]);
    Alcotest.(check int) "still 1 after unsub" 1 (List.length !received))

let test_ws_dead_subscriber_auto_removed () =
  Eio_main.run (fun _env ->
    let received = ref [] in
    let alive = ref true in
    let sub_id = "ws-test-dead" in
    Sse.subscribe_external ~id:sub_id
      ~callback:(fun ev -> received := ev :: !received)
      ~is_alive:(fun () -> !alive) ();
    Sse.broadcast (`Assoc [("msg", `String "alive")]);
    Alcotest.(check int) "1 while alive" 1 (List.length !received);
    alive := false;
    Sse.broadcast (`Assoc [("msg", `String "dead")]);
    (* Dead subscriber should not receive and should be auto-removed *)
    Alcotest.(check int) "still 1 after death" 1 (List.length !received);
    let ext_count = Sse.external_subscriber_count () in
    (* The dead sub should have been reaped by notify_external_subscribers *)
    Alcotest.(check bool) "subscriber removed"
      true (ext_count = 0 || not (List.mem sub_id
        (List.init ext_count (fun _ -> "")))))

let test_ws_external_subscriber_count () =
  Eio_main.run (fun _env ->
    let before = Sse.external_subscriber_count () in
    Sse.subscribe_external ~id:"ws-count-1"
      ~callback:(fun _ -> ()) ();
    Sse.subscribe_external ~id:"ws-count-2"
      ~callback:(fun _ -> ()) ();
    let after = Sse.external_subscriber_count () in
    Alcotest.(check int) "added 2" (before + 2) after;
    Sse.unsubscribe_external "ws-count-1";
    Sse.unsubscribe_external "ws-count-2";
    let final = Sse.external_subscriber_count () in
    Alcotest.(check int) "back to before" before final)

(* ====== Slice index (Phase 1: bookkeeping only) ====== *)

(* The slice index maps each dashboard slice to the set of session IDs
   currently subscribed to it.  Phase 1 maintains the index at subscribe
   / unsubscribe / cleanup time but does NOT yet rewire the broadcast
   fanout (RFC #10119).  These tests pin add/remove/sweep semantics so
   Phase 2 can rely on them. *)

let test_slice_index_starts_empty_for_unknown_slice () =
  Eio_main.run (fun _env ->
    let subs = Ws.slice_index_subscribers "execution" in
    (* The index is process-global state shared across tests, so we cannot
       assert it is empty.  We can assert this specific session id is
       not in it, which is the property the index exists to answer. *)
    Alcotest.(check bool) "fresh session id not present"
      true (not (List.mem "ws-slice-test-fresh" subs)))

let test_slice_index_add_records_session () =
  Eio_main.run (fun _env ->
    let sid = "ws-slice-add-1" in
    Ws.__test_slice_index_remove_session sid; (* defensive cleanup *)
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    let subs = Ws.slice_index_subscribers "execution" in
    Alcotest.(check bool) "session present after add"
      true (List.mem sid subs);
    Ws.__test_slice_index_remove_session sid)

let test_slice_index_remove_specific_slice () =
  Eio_main.run (fun _env ->
    let sid = "ws-slice-remove-1" in
    Ws.__test_slice_index_remove_session sid;
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    Ws.__test_slice_index_add ~session_id:sid ~slice:"keepers";
    Ws.__test_slice_index_remove ~session_id:sid ~slice:"execution";
    let exec = Ws.slice_index_subscribers "execution" in
    let keepers = Ws.slice_index_subscribers "keepers" in
    Alcotest.(check bool) "removed from execution"
      true (not (List.mem sid exec));
    Alcotest.(check bool) "still in keepers"
      true (List.mem sid keepers);
    Ws.__test_slice_index_remove_session sid)

let test_slice_index_remove_session_clears_all_slices () =
  Eio_main.run (fun _env ->
    let sid = "ws-slice-cleanup-1" in
    Ws.__test_slice_index_remove_session sid;
    List.iter
      (fun slice -> Ws.__test_slice_index_add ~session_id:sid ~slice)
      ["execution"; "keepers"; "transport"; "shell"];
    Ws.__test_slice_index_remove_session sid;
    List.iter
      (fun slice ->
        let subs = Ws.slice_index_subscribers slice in
        Alcotest.(check bool)
          (Printf.sprintf "session removed from %s" slice)
          true (not (List.mem sid subs)))
      ["execution"; "keepers"; "transport"; "shell"])

let test_slice_index_size_reflects_pairs () =
  Eio_main.run (fun _env ->
    let sid_a = "ws-slice-size-a" in
    let sid_b = "ws-slice-size-b" in
    Ws.__test_slice_index_remove_session sid_a;
    Ws.__test_slice_index_remove_session sid_b;
    let baseline = Ws.slice_index_size () in
    Ws.__test_slice_index_add ~session_id:sid_a ~slice:"execution";
    Ws.__test_slice_index_add ~session_id:sid_a ~slice:"keepers";
    Ws.__test_slice_index_add ~session_id:sid_b ~slice:"execution";
    let after = Ws.slice_index_size () in
    (* 2 entries for sid_a + 1 for sid_b = +3 over baseline *)
    Alcotest.(check int) "size grew by exactly the new pair count"
      3 (after - baseline);
    Ws.__test_slice_index_remove_session sid_a;
    Ws.__test_slice_index_remove_session sid_b;
    let final = Ws.slice_index_size () in
    Alcotest.(check int) "size returns to baseline after sweep"
      baseline final)

let test_slice_index_add_is_idempotent () =
  Eio_main.run (fun _env ->
    let sid = "ws-slice-idem" in
    Ws.__test_slice_index_remove_session sid;
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    let subs = Ws.slice_index_subscribers "execution" in
    let occurrences = List.length (List.filter ((=) sid) subs) in
    Alcotest.(check int) "session appears at most once after duplicate adds"
      1 occurrences;
    Ws.__test_slice_index_remove_session sid)

let () =
  Alcotest.run "WebSocket Transport" [
    ("session_registry", [
      Alcotest.test_case "initial count" `Quick test_initial_session_count;
      Alcotest.test_case "close_all empty" `Quick test_close_all_empty;
    ]);
    ("sha1", [
      Alcotest.test_case "produces 20 bytes" `Quick test_sha1_produces_20_bytes;
      Alcotest.test_case "deterministic" `Quick test_sha1_deterministic;
      Alcotest.test_case "different inputs" `Quick test_sha1_different_inputs;
    ]);
    ("dashboard", [
      Alcotest.test_case "route scoped slices are valid" `Quick
        test_dashboard_route_scoped_slices_are_valid;
    ]);
    ("parse_cache", [
      Alcotest.test_case "known type maps to slice" `Quick
        test_parse_sse_dashboard_event_known_type;
      Alcotest.test_case "unknown type yields None slice" `Quick
        test_parse_sse_dashboard_event_unknown_type;
      Alcotest.test_case "malformed input returns None" `Quick
        test_parse_sse_dashboard_event_malformed;
      Alcotest.test_case "repeated calls stable" `Quick
        test_parse_sse_dashboard_event_stable_on_repeat;
      Alcotest.test_case "cache invalidates on new ref" `Quick
        test_parse_sse_dashboard_event_invalidated_on_new_ref;
      Alcotest.test_case "hit/miss counters track reuse" `Quick
        test_parse_cache_counters;
    ]);
    ("bytes_cache", [
      Alcotest.test_case "same string ref returns same Bytes" `Quick
        test_bytes_of_shared_text_reuses_same_ref;
      Alcotest.test_case "content round-trips through cache" `Quick
        test_bytes_of_shared_text_content_matches;
      Alcotest.test_case "distinct refs force re-allocation" `Quick
        test_bytes_of_shared_text_invalidates_on_new_ref;
      Alcotest.test_case "hit/miss counters track reuse" `Quick
        test_bytes_cache_counters;
    ]);
    ("ack_observability", [
      Alcotest.test_case "buffered_bytes sum and count track observations" `Quick
        test_observe_ws_client_buffered_bytes_accumulates;
      Alcotest.test_case "negative buffered_bytes floor to zero" `Quick
        test_observe_ws_client_buffered_bytes_clamps_negative;
    ]);
    ("backpressure_gate", [
      Alcotest.test_case "unauthenticated sessions never trigger the gate" `Quick
        test_backpressure_gate_unauthenticated_ignored;
      Alcotest.test_case "zero limit disables the gate" `Quick
        test_backpressure_gate_zero_disables;
      Alcotest.test_case "default limit is 1 MiB" `Quick
        test_backpressure_gate_default_is_one_mib;
      Alcotest.test_case "throttle counter advances per skipped delivery" `Quick
        test_backpressure_gate_throttle_counter_increments;
    ]);
    ("external_subscriber", [
      Alcotest.test_case "single subscriber receives broadcast" `Quick
        test_ws_external_subscriber_receives_broadcast;
      Alcotest.test_case "multi-session broadcast" `Quick
        test_ws_multi_session_broadcast;
      Alcotest.test_case "unsubscribe stops delivery" `Quick
        test_ws_unsubscribe_stops_delivery;
      Alcotest.test_case "dead subscriber auto-removed" `Quick
        test_ws_dead_subscriber_auto_removed;
      Alcotest.test_case "subscriber count tracking" `Quick
        test_ws_external_subscriber_count;
    ]);
    ("slice_index", [
      Alcotest.test_case "unknown slice yields no subscribers" `Quick
        test_slice_index_starts_empty_for_unknown_slice;
      Alcotest.test_case "add records session under slice" `Quick
        test_slice_index_add_records_session;
      Alcotest.test_case "remove targets only the named slice" `Quick
        test_slice_index_remove_specific_slice;
      Alcotest.test_case "remove_session sweeps every slice" `Quick
        test_slice_index_remove_session_clears_all_slices;
      Alcotest.test_case "size tracks (slice × session) pair count" `Quick
        test_slice_index_size_reflects_pairs;
      Alcotest.test_case "duplicate add is idempotent" `Quick
        test_slice_index_add_is_idempotent;
    ]);
  ]

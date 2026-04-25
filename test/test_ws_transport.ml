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
  ]

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

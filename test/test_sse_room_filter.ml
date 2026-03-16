(** Tests for Sse_room_filter — room-based SSE event isolation *)

module F = Masc_mcp.Sse_room_filter

let setup () = F.clear ()

let test_register_and_lookup () =
  setup ();
  F.register ~session_id:"s1" ~room_id:"room-a";
  Alcotest.(check (option string)) "room-a"
    (Some "room-a") (F.room_of ~session_id:"s1");
  Alcotest.(check int) "1 registered" 1 (F.registered_count ())

let test_sessions_in_room () =
  setup ();
  F.register ~session_id:"s1" ~room_id:"room-a";
  F.register ~session_id:"s2" ~room_id:"room-a";
  F.register ~session_id:"s3" ~room_id:"room-b";
  let in_a = F.sessions_in_room ~room_id:"room-a" in
  Alcotest.(check int) "2 in room-a" 2 (List.length in_a);
  Alcotest.(check bool) "s1 in room-a" true (List.mem "s1" in_a);
  Alcotest.(check bool) "s2 in room-a" true (List.mem "s2" in_a);
  let in_b = F.sessions_in_room ~room_id:"room-b" in
  Alcotest.(check int) "1 in room-b" 1 (List.length in_b)

let test_unregister () =
  setup ();
  F.register ~session_id:"s1" ~room_id:"room-a";
  F.unregister ~session_id:"s1";
  Alcotest.(check (option string)) "gone"
    None (F.room_of ~session_id:"s1");
  Alcotest.(check int) "0 in room-a" 0
    (List.length (F.sessions_in_room ~room_id:"room-a"))

let test_room_switch () =
  setup ();
  F.register ~session_id:"s1" ~room_id:"room-a";
  F.register ~session_id:"s1" ~room_id:"room-b";
  Alcotest.(check (option string)) "now room-b"
    (Some "room-b") (F.room_of ~session_id:"s1");
  Alcotest.(check int) "0 in room-a" 0
    (List.length (F.sessions_in_room ~room_id:"room-a"));
  Alcotest.(check int) "1 in room-b" 1
    (List.length (F.sessions_in_room ~room_id:"room-b"))

(* --- should_receive tests --- *)

let test_global_event_received_by_all () =
  setup ();
  F.register ~session_id:"s1" ~room_id:"room-a";
  F.register ~session_id:"s2" ~room_id:"room-b";
  Alcotest.(check bool) "s1 global" true
    (F.should_receive ~session_id:"s1" ~event_room_id:None);
  Alcotest.(check bool) "s2 global" true
    (F.should_receive ~session_id:"s2" ~event_room_id:None)

let test_room_event_isolation () =
  setup ();
  F.register ~session_id:"s1" ~room_id:"room-a";
  F.register ~session_id:"s2" ~room_id:"room-b";
  Alcotest.(check bool) "s1 receives room-a" true
    (F.should_receive ~session_id:"s1" ~event_room_id:(Some "room-a"));
  Alcotest.(check bool) "s1 not receive room-b" false
    (F.should_receive ~session_id:"s1" ~event_room_id:(Some "room-b"));
  Alcotest.(check bool) "s2 receives room-b" true
    (F.should_receive ~session_id:"s2" ~event_room_id:(Some "room-b"));
  Alcotest.(check bool) "s2 not receive room-a" false
    (F.should_receive ~session_id:"s2" ~event_room_id:(Some "room-a"))

let test_unregistered_receives_nothing () =
  setup ();
  Alcotest.(check bool) "unregistered denied" false
    (F.should_receive ~session_id:"ghost" ~event_room_id:(Some "room-a"))

(* --- broadcast_to_room test --- *)

let test_broadcast_to_room () =
  setup ();
  F.register ~session_id:"s1" ~room_id:"room-a";
  F.register ~session_id:"s2" ~room_id:"room-a";
  F.register ~session_id:"s3" ~room_id:"room-b";
  let sent = ref [] in
  let send_fn sid payload =
    sent := (sid, payload) :: !sent in
  F.broadcast_to_room ~room_id:"room-a" ~send_fn (`String "hello");
  Alcotest.(check int) "2 sends" 2 (List.length !sent);
  let sids = List.map fst !sent in
  Alcotest.(check bool) "s1 got msg" true (List.mem "s1" sids);
  Alcotest.(check bool) "s2 got msg" true (List.mem "s2" sids);
  Alcotest.(check bool) "s3 not in sends" false (List.mem "s3" sids)

let test_broadcast_empty_room () =
  setup ();
  let sent = ref [] in
  let send_fn sid payload = sent := (sid, payload) :: !sent in
  F.broadcast_to_room ~room_id:"empty" ~send_fn (`String "noop");
  Alcotest.(check int) "0 sends" 0 (List.length !sent)

let () =
  Alcotest.run "Sse_room_filter" [
    "registration", [
      Alcotest.test_case "register and lookup" `Quick test_register_and_lookup;
      Alcotest.test_case "sessions in room" `Quick test_sessions_in_room;
      Alcotest.test_case "unregister" `Quick test_unregister;
      Alcotest.test_case "room switch" `Quick test_room_switch;
    ];
    "should_receive", [
      Alcotest.test_case "global event" `Quick test_global_event_received_by_all;
      Alcotest.test_case "room isolation" `Quick test_room_event_isolation;
      Alcotest.test_case "unregistered" `Quick test_unregistered_receives_nothing;
    ];
    "broadcast", [
      Alcotest.test_case "to room" `Quick test_broadcast_to_room;
      Alcotest.test_case "empty room" `Quick test_broadcast_empty_room;
    ];
  ]

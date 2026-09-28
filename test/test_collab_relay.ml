(** Stack 2 tests for RFC-0471: relay wire shapes (roles, control JSON,
    close codes, request-target parsing) and the in-memory relay core
    (join/route/leave semantics over [Collab_relay.t]). *)

open Alcotest

module Wire = Collab_wire
module Relay = Collab_relay
module Env = Collab_envelope

let room_a = String.make 16 'a'
let room_b = String.make 16 'b'

let b64 s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s
;;

let pack_ok ~peer payload =
  match Env.pack ~peer payload with
  | Ok bytes -> bytes
  | Error (Env.Peer_id_out_of_range n) ->
    fail ("pack peer " ^ string_of_int n)
;;

(* ── wire: roles ── *)

let test_role_strings () =
  check
    (option (testable Fmt.nop ( = )))
    "host"
    (Some Wire.Host)
    (Wire.role_of_string "host");
  check
    (option (testable Fmt.nop ( = )))
    "guest"
    (Some Wire.Guest)
    (Wire.role_of_string "guest");
  check
    (option (testable Fmt.nop ( = )))
    "Host rejected"
    None
    (Wire.role_of_string "Host");
  check
    (option (testable Fmt.nop ( = )))
    "empty rejected"
    None
    (Wire.role_of_string "");
  check string "host renders" "host" (Wire.string_of_role Wire.Host);
  check string "guest renders" "guest" (Wire.string_of_role Wire.Guest)
;;

(* ── wire: control JSON ── *)

let test_control_roundtrips () =
  let cases =
    [
      Wire.Peer_joined { peer = 1 }, {|{"t":"peer-joined","peer":1}|};
      Wire.Peer_left { peer = 12 }, {|{"t":"peer-left","peer":12}|};
      Wire.Room_closed, {|{"t":"room-closed"}|};
    ]
  in
  List.iter
    (fun (control, json) ->
      check string "encodes" json (Wire.control_json control);
      check
        (option (testable Fmt.nop ( = )))
        "decodes"
        (Some control)
        (Wire.control_of_string json))
    cases
;;

let test_control_rejects () =
  let bad =
    [
      "not json";
      {|{"t":"peer-joined"}|};
      {|{"t":"peer-joined","peer":0}|};
      {|{"t":"peer-joined","peer":-3}|};
      {|{"t":"peer-joined","peer":"1"}|};
      {|{"t":"peer-joined","peer":1.0}|};
      {|{"t":"peer-banned","peer":1}|};
      {|{"t":42}|};
      {|{}|};
      {|[]|};
      {|"room-closed"|};
    ]
  in
  List.iter
    (fun s ->
      check
        (option (testable Fmt.nop ( = )))
        ("rejects " ^ s)
        None
        (Wire.control_of_string s))
    bad
;;

let test_close_codes () =
  check int "room closed" 4001 (Wire.close_code Wire.Close_room_closed);
  check int "no such room" 4004 (Wire.close_code Wire.Close_no_such_room);
  check int "host conflict" 4009 (Wire.close_code Wire.Close_host_conflict);
  check int "room full" 4029 (Wire.close_code Wire.Close_room_full);
  check string "closed msg" "room closed"
    (Wire.close_message Wire.Close_room_closed);
  check string "missing msg" "no such room"
    (Wire.close_message Wire.Close_no_such_room)
;;

(* ── wire: request targets ── *)

let req_err_to_string = function
  | Wire.Bad_path -> "Bad_path"
  | Wire.Bad_room_id -> "Bad_room_id"
  | Wire.Missing_role -> "Missing_role"
  | Wire.Bad_role -> "Bad_role"
  | Wire.Duplicate_role -> "Duplicate_role"
;;

let req_err = testable Fmt.nop (fun a b ->
    String.equal (req_err_to_string a) (req_err_to_string b))
;;

let test_request_targets () =
  let room_b64 = b64 room_a in
  let ok_host = Ok (room_a, Wire.Host) in
  let ok_guest = Ok (room_a, Wire.Guest) in
  let parsed =
    testable Fmt.nop (fun (r1, c1) (r2, c2) ->
        String.equal r1 r2 && c1 = c2)
  in
  let check_ok msg target expected =
    check (result parsed req_err) msg expected
      (Wire.parse_request_target ~target)
  in
  let check_err msg target expected =
    check
      (result parsed req_err)
      msg
      (Error expected)
      (Wire.parse_request_target ~target)
  in
  check_ok "host" ("/r/" ^ room_b64 ^ "?role=host") ok_host;
  check_ok "guest" ("/r/" ^ room_b64 ^ "?role=guest") ok_guest;
  check_ok
    "extra params ignored"
    ("/r/" ^ room_b64 ^ "?x=1&role=guest&y=2")
    ok_guest;
  check_err
    "role value with = inside"
    ("/r/" ^ room_b64 ^ "?role=a=b")
    Wire.Bad_role;
  check_err "bare path" "/r/" Wire.Bad_path;
  check_err "no prefix" ("/x/" ^ room_b64 ^ "?role=guest") Wire.Bad_path;
  check_err "nested suffix" ("/r/a/b?role=guest") Wire.Bad_path;
  check_err "bad alphabet" ("/r/***?role=guest") Wire.Bad_room_id;
  check_err "short room" ("/r/AAAA?role=guest") Wire.Bad_room_id;
  check_err "no query" ("/r/" ^ room_b64) Wire.Missing_role;
  check_err "empty query" ("/r/" ^ room_b64 ^ "?") Wire.Missing_role;
  check_err
    "unrelated query"
    ("/r/" ^ room_b64 ^ "?x=1")
    Wire.Missing_role;
  check_err
    "bad role"
    ("/r/" ^ room_b64 ^ "?role=owner")
    Wire.Bad_role;
  check_err
    "duplicate role"
    ("/r/" ^ room_b64 ^ "?role=guest&role=host")
    Wire.Duplicate_role
;;

(* ── relay: join ── *)

let test_join_lifecycle () =
  let t = Relay.create () in
  check
    (result (testable Fmt.nop ( = )) (testable Fmt.nop ( = )))
    "host creates room"
    (Ok Relay.Host_accepted)
    (Relay.join t ~room:room_a ~role:Wire.Host);
  check
    (result (testable Fmt.nop ( = )) (testable Fmt.nop ( = )))
    "second host refused"
    (Error Relay.Host_already_connected)
    (Relay.join t ~room:room_a ~role:Wire.Host);
  check
    (result (testable Fmt.nop ( = )) (testable Fmt.nop ( = )))
    "guest 1"
    (Ok (Relay.Guest_accepted { peer = 1 }))
    (Relay.join t ~room:room_a ~role:Wire.Guest);
  check
    (result (testable Fmt.nop ( = )) (testable Fmt.nop ( = )))
    "guest 2"
    (Ok (Relay.Guest_accepted { peer = 2 }))
    (Relay.join t ~room:room_a ~role:Wire.Guest);
  check
    (result (testable Fmt.nop ( = )) (testable Fmt.nop ( = )))
    "guest to missing room"
    (Error Relay.Join_no_such_room)
    (Relay.join t ~room:room_b ~role:Wire.Guest)
;;

let test_room_full_and_no_reuse () =
  let t = Relay.create () in
  (match Relay.join t ~room:room_a ~role:Wire.Host with
   | Ok Relay.Host_accepted -> ()
   | _ -> fail "host join");
  let peers = ref [] in
  for _ = 1 to Relay.max_guests_per_room do
    match Relay.join t ~room:room_a ~role:Wire.Guest with
    | Ok (Relay.Guest_accepted { peer }) -> peers := peer :: !peers
    | Ok Relay.Host_accepted -> fail "guest join returned host"
    | Error _ -> fail "guest refused before cap"
  done;
  check int "cap reached" Relay.max_guests_per_room (List.length !peers);
  check
    (result (testable Fmt.nop ( = )) (testable Fmt.nop ( = )))
    "17th guest refused"
    (Error Relay.Room_full)
    (Relay.join t ~room:room_a ~role:Wire.Guest);
  (* A leave frees a slot but the id is never reused. *)
  check
    (testable Fmt.nop ( = ))
    "guest 1 leaves"
    Relay.Guest_departed
    (Relay.guest_left t ~room:room_a ~peer:1);
  (match Relay.join t ~room:room_a ~role:Wire.Guest with
   | Ok (Relay.Guest_accepted { peer }) ->
     check int "id climbs on" (Relay.max_guests_per_room + 1) peer
   | _ -> fail "rejoin after leave")
;;

(* ── relay: route ── *)

let test_broadcast_and_target () =
  let t = Relay.create () in
  ignore (Relay.join t ~room:room_a ~role:Wire.Host);
  ignore (Relay.join t ~room:room_a ~role:Wire.Guest);
  ignore (Relay.join t ~room:room_a ~role:Wire.Guest);
  let envelope = pack_ok ~peer:Env.broadcast_peer "frame" in
  (match
     Relay.route t ~room:room_a ~sender:Relay.Host ~envelope
   with
   | Relay.To_guests { peers; envelope = out } ->
     check (list int) "broadcast peers" [ 1; 2 ] peers;
     check string "envelope passes through" envelope out
   | _ -> fail "broadcast misrouted");
  let direct = pack_ok ~peer:2 "frame" in
  (match Relay.route t ~room:room_a ~sender:Relay.Host ~envelope:direct with
   | Relay.To_guests { peers; envelope = out } ->
     check (list int) "target peer" [ 2 ] peers;
     check string "direct passes through" direct out
   | _ -> fail "targeted misrouted");
  let missing = pack_ok ~peer:9 "frame" in
  (match Relay.route t ~room:room_a ~sender:Relay.Host ~envelope:missing with
   | Relay.Drop { reason = Relay.Route_guest_not_in_room { peer = 9 } } -> ()
   | _ -> fail "unknown target not dropped")
;;

let test_guest_to_host_rewrite () =
  let t = Relay.create () in
  ignore (Relay.join t ~room:room_a ~role:Wire.Host);
  ignore (Relay.join t ~room:room_a ~role:Wire.Guest);
  ignore (Relay.join t ~room:room_a ~role:Wire.Guest);
  (* Guest 2 sends with target 0; the host must see sender id 2. *)
  let envelope = pack_ok ~peer:0 "prompt" in
  (match
     Relay.route t ~room:room_a ~sender:(Relay.Guest 2) ~envelope
   with
   | Relay.To_host { envelope = out } ->
     (match Env.unpack out with
      | Some (peer, payload) ->
        check int "sender rewritten" 2 peer;
        check string "payload kept" "prompt" payload
      | None -> fail "rewritten envelope malformed")
   | _ -> fail "guest frame misrouted");
  (* A guest's incoming target is ignored: it still reaches the host. *)
  let odd = pack_ok ~peer:1 "prompt" in
  (match Relay.route t ~room:room_a ~sender:(Relay.Guest 2) ~envelope:odd with
   | Relay.To_host _ -> ()
   | _ -> fail "guest frame with target dropped");
  (* Frames from a guest that never joined are dropped. *)
  (match Relay.route t ~room:room_a ~sender:(Relay.Guest 7) ~envelope with
   | Relay.Drop { reason = Relay.Route_guest_not_in_room { peer = 7 } } -> ()
   | _ -> fail "stranger frame not dropped")
;;

let test_route_drops () =
  let t = Relay.create () in
  ignore (Relay.join t ~room:room_a ~role:Wire.Host);
  let envelope = pack_ok ~peer:0 "frame" in
  (match Relay.route t ~room:room_a ~sender:Relay.Host ~envelope:"abc" with
   | Relay.Drop { reason = Relay.Malformed_envelope } -> ()
   | _ -> fail "short envelope not dropped");
  (match Relay.route t ~room:room_b ~sender:Relay.Host ~envelope with
   | Relay.Drop { reason = Relay.Route_no_such_room } -> ()
   | _ -> fail "unknown room not dropped")
;;

(* ── relay: leave ── *)

let test_teardown () =
  let t = Relay.create () in
  ignore (Relay.join t ~room:room_a ~role:Wire.Host);
  ignore (Relay.join t ~room:room_a ~role:Wire.Guest);
  ignore (Relay.join t ~room:room_a ~role:Wire.Guest);
  ignore (Relay.join t ~room:room_a ~role:Wire.Guest);
  check (list int) "teardown lists guests" [ 1; 2; 3 ]
    (Relay.host_left t ~room:room_a);
  check (list int) "second teardown empty" []
    (Relay.host_left t ~room:room_a);
  check
    (result (testable Fmt.nop ( = )) (testable Fmt.nop ( = )))
    "room gone after teardown"
    (Error Relay.Join_no_such_room)
    (Relay.join t ~room:room_a ~role:Wire.Guest);
  (* A fresh host may recreate the room; ids restart. *)
  ignore (Relay.join t ~room:room_a ~role:Wire.Host);
  (match Relay.join t ~room:room_a ~role:Wire.Guest with
   | Ok (Relay.Guest_accepted { peer }) -> check int "ids restart" 1 peer
   | _ -> fail "recreate failed")
;;

let test_guest_leave_cases () =
  let t = Relay.create () in
  ignore (Relay.join t ~room:room_a ~role:Wire.Host);
  ignore (Relay.join t ~room:room_a ~role:Wire.Guest);
  let departure = testable Fmt.nop ( = ) in
  check departure "leave ok" Relay.Guest_departed
    (Relay.guest_left t ~room:room_a ~peer:1);
  check departure "leave twice" Relay.Leave_no_such_guest
    (Relay.guest_left t ~room:room_a ~peer:1);
  check departure "leave missing room" Relay.Leave_no_such_room
    (Relay.guest_left t ~room:room_b ~peer:1)
;;

let () =
  run
    "collab-relay"
    [
      ( "wire",
        [
          test_case "role strings" `Quick test_role_strings;
          test_case "control roundtrips" `Quick test_control_roundtrips;
          test_case "control rejects" `Quick test_control_rejects;
          test_case "close codes" `Quick test_close_codes;
          test_case "request targets" `Quick test_request_targets;
        ] );
      ( "join",
        [
          test_case "join lifecycle" `Quick test_join_lifecycle;
          test_case "room full and no reuse" `Quick test_room_full_and_no_reuse;
        ] );
      ( "route",
        [
          test_case "broadcast and target" `Quick test_broadcast_and_target;
          test_case "guest to host rewrite" `Quick test_guest_to_host_rewrite;
          test_case "route drops" `Quick test_route_drops;
        ] );
      ( "leave",
        [
          test_case "teardown" `Quick test_teardown;
          test_case "guest leave cases" `Quick test_guest_leave_cases;
        ] );
    ]
;;

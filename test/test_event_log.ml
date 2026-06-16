(** Test Event_log canonical id and ordering (P2-2). *)

open Masc

let event_log_test name f =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let mono_clock = Eio.Stdenv.mono_clock env in
      let net = Eio.Stdenv.net env in
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
          Event_log.For_testing.reset ();
          f ()))))
;;

let publish_returns_id () =
  let id =
    Event_log.publish ~source:"test" ~kind:"ping" (`Assoc [ ("x", `Int 1) ])
  in
  Alcotest.(check bool) "id non-empty" true (String.length id > 0);
  Alcotest.(check bool) "id contains underscore" true (String.contains id '_')
;;

let recent_newest_first () =
  let id1 =
    Event_log.publish ~source:"test" ~kind:"first" (`Assoc [ ("n", `Int 1) ])
  in
  Unix.sleepf 0.001;
  let id2 =
    Event_log.publish ~source:"test" ~kind:"second" (`Assoc [ ("n", `Int 2) ])
  in
  let recent = Event_log.recent 2 in
  Alcotest.(check int) "two events" 2 (List.length recent);
  Alcotest.(check string) "first recent is newest" id2 (List.hd recent).id;
  Alcotest.(check string) "second recent is older" id1 (List.nth recent 1).id
;;

let recent_since_id_pagination () =
  let _id1 =
    Event_log.publish ~source:"test" ~kind:"a" (`Assoc [ ("n", `Int 1) ])
  in
  Unix.sleepf 0.001;
  let id2 =
    Event_log.publish ~source:"test" ~kind:"b" (`Assoc [ ("n", `Int 2) ])
  in
  Unix.sleepf 0.001;
  let id3 =
    Event_log.publish ~source:"test" ~kind:"c" (`Assoc [ ("n", `Int 3) ])
  in
  let recent = Event_log.recent ~since_id:id3 1 in
  Alcotest.(check int) "one event after id3" 1 (List.length recent);
  Alcotest.(check string) "event is id2" id2 (List.hd recent).id
;;

let to_json_roundtrip () =
  let id =
    Event_log.publish ~source:"rest" ~kind:"tool_call"
      (`Assoc [ ("tool", `String "x") ])
  in
  match Event_log.recent 1 with
  | [ e ] ->
    let json = Event_log.to_json e in
    Alcotest.(check string) "json id" id
      (Safe_ops.json_string ~default:"" "id" json);
    Alcotest.(check string) "json source" "rest"
      (Safe_ops.json_string ~default:"" "source" json);
    Alcotest.(check string) "json kind" "tool_call"
      (Safe_ops.json_string ~default:"" "kind" json)
  | _ -> Alcotest.fail "expected one event"
;;

let () =
  Alcotest.run
    "Event_log P2-2"
    [ ( "canonical_event_log"
      , [ event_log_test "publish returns canonical id" publish_returns_id
        ; event_log_test "recent newest first" recent_newest_first
        ; event_log_test "recent since_id pagination" recent_since_id_pagination
        ; event_log_test "to_json roundtrip" to_json_roundtrip
        ] )
    ]
;;

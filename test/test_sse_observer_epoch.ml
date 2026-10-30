open Alcotest

module Sse = Masc.Sse
module Wire = Sse_wire

let with_observer f =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let auth = Masc_test_deps.make_sse_auth workspace "epoch-observer" in
  let session_id = "epoch-observer-" ^ string_of_int (Random.bits ()) in
  let original_buffer = Sse.event_buffer_events_for_test () in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  Fun.protect
    ~finally:(fun () ->
      Sse.unregister session_id;
      Sse.set_event_buffer_for_test original_buffer;
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () ->
      let connect ~instance_id ~headers ~last_event_id =
        let handshake, cursor =
          Wire.negotiate_observer ~instance_id ~headers ~last_event_id
        in
        match Sse.register ~kind:Sse.Observer ~auth session_id
                ~last_event_id:(Option.value ~default:0 cursor) with
        | Error error -> fail (Sse.registration_error_to_string error)
        | Ok (_, stream, _) -> handshake, cursor, stream
      in
      f ~session_id ~connect)
;;

let tool_result text =
  `Assoc
    [ "type", `String "keeper_tool_call"
    ; "name", `String "epoch-observer"
    ; "tool_name", `String "keeper_tasks_list"
    ; "ts_unix", `Float 1.0
    ; "duration_ms", `Int 1
    ; "disposition", `String "completed"
    ; "tool_args", `Assoc [ "view", `String "compact" ]
    ; "tool_result", `Assoc [ "text", `String text ]
    ]
;;

let take stream =
  match Eio.Stream.take_nonblocking stream with
  | Some delivery -> delivery
  | None -> fail "Expected an actual SSE delivery"
;;

let test_same_instance_replays_disconnected_tool_result () =
  with_observer (fun ~session_id ~connect ->
    let first, cursor, stream =
      connect ~instance_id:"instance-a" ~headers:[] ~last_event_id:None
    in
    check bool "first connection is live only" true (first.replay = Wire.Fresh);
    check (option int) "no invented initial replay cursor" None cursor;
    Sse.broadcast_to Sse.Observers (tool_result "before disconnect");
    let delivered = take stream in
    Sse.unregister session_id;
    let missed = tool_result "while disconnected" in
    Sse.broadcast_to Sse.Observers missed;
    let missed_id = Sse.current_id () in
    let headers =
      Wire.observer_cursor_headers
        (Some { instance_id = "instance-a"; event_id = delivered.event_id })
    in
    let handshake, cursor, stream =
      connect ~instance_id:"instance-a" ~headers
        ~last_event_id:(Some delivered.event_id)
    in
    check bool "same epoch resumes" true (handshake.replay = Wire.Resumed);
    let replayed =
      match cursor with
      | None -> fail "same-instance cursor lost"
      | Some event_id ->
        let replay = Sse.replay_after_for_session ~session_id ~kind:Sse.Observer event_id in
        check bool "nothing expired past the cursor" true (replay.Sse.continuity = Sse.Continuous);
        replay.Sse.deliveries
    in
    check (list int) "only the disconnected delivery is replayed" [ missed_id ]
      (List.map (fun (event : Sse.delivery) -> event.event_id) replayed);
    check bool "replay preserves tool input/output JSON" true
      ((List.hd replayed).payload = missed);
    let live = tool_result "after reconnect" in
    Sse.broadcast_to Sse.Observers live;
    check bool "subsequent live delivery retained" true ((take stream).payload = live))
;;

let test_unusable_epoch_cannot_suppress_new_live expected headers =
  with_observer (fun ~session_id:_ ~connect ->
    let handshake, cursor, stream =
      connect ~instance_id:"instance-new" ~headers ~last_event_id:(Some max_int)
    in
    check bool "explicit reset reason" true (handshake.replay = Wire.Reset expected);
    check (option int) "old high cursor discarded before registration" None cursor;
    let payload = tool_result "new process event with lower numeric ID" in
    Sse.broadcast_to Sse.Observers payload;
    let received = take stream in
    check bool "new lower ID reaches live subscriber" true
      (received.event_id < max_int && received.payload = payload);
    check bool "response carries the new epoch and reset reason" true
      (Wire.decode_observer_response (Wire.observer_response_headers handshake)
       = Ok (Some handshake)))
;;

let delivery ~event_id ~emitted_at =
  let payload = tool_result ("event " ^ string_of_int event_id) in
  { Sse.event_id
  ; frame = Wire.format_event_yojson ~id:event_id payload
  ; payload
  ; emitted_at
  ; audience = Sse.Broadcast_audience Sse.Observers
  }
;;

(* Runs [f] on an empty replay buffer and puts the old one back after. *)
let with_empty_buffer f =
  let original_buffer = Sse.event_buffer_events_for_test () in
  Fun.protect
    ~finally:(fun () -> Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      f ())
;;

let continuity after =
  (Sse.replay_after_for_session ~session_id:"gap-observer" ~kind:Sse.Observer after).Sse.continuity
;;

(* The buffer keeps [MASC_SSE_REPLAY_BUFFER_SIZE] events (1000 at most), so
   1001 of them push the first one out. A cursor before it has missed it; a
   cursor at it has not. *)
let test_count_eviction_is_a_gap () =
  with_empty_buffer (fun () ->
    let now = Time_compat.now () in
    for event_id = 1 to 1001 do
      Sse.buffer_event (delivery ~event_id ~emitted_at:now)
    done;
    check bool "a cursor before the dropped event resumes after a gap" true
      (continuity 0 = Sse.After_gap { missed_through = 1 });
    check bool "a cursor at the dropped event missed nothing" true (continuity 1 = Sse.Continuous))
;;

let test_age_eviction_is_a_gap () =
  with_empty_buffer (fun () ->
    let now = Time_compat.now () in
    Sse.buffer_event (delivery ~event_id:5 ~emitted_at:0.);
    Sse.buffer_event (delivery ~event_id:6 ~emitted_at:now);
    check bool "nothing has expired yet" true (continuity 3 = Sse.Continuous);
    check int "the old event expires" 1 (Sse.cleanup_expired_events ());
    check bool "a cursor before the expired event resumes after a gap" true
      (continuity 3 = Sse.After_gap { missed_through = 5 });
    check bool "a cursor at the expired event missed nothing" true (continuity 5 = Sse.Continuous);
    check (list int) "the kept event is still replayed" [ 6 ]
      (List.map
         (fun (event : Sse.delivery) -> event.event_id)
         (Sse.replay_after_for_session ~session_id:"gap-observer" ~kind:Sse.Observer 3).Sse.deliveries))
;;

let test_a_gap_reaches_the_observer_headers () =
  let resumed = { Wire.instance_id = "instance-a"; replay = Wire.Resumed } in
  let after_gap = Wire.observer_after_replay resumed ~missed_through:(Some 41) in
  check bool "a resumed handshake records the gap" true
    (after_gap.replay = Wire.Resumed_after_gap { missed_through = 41 });
  check bool "no gap leaves it resumed" true
    (Wire.observer_after_replay resumed ~missed_through:None = resumed);
  let fresh = { resumed with replay = Wire.Fresh } in
  check bool "a fresh handshake read no replay, so it has no gap" true
    (Wire.observer_after_replay fresh ~missed_through:(Some 41) = fresh);
  check bool "the gap survives the response headers" true
    (Wire.decode_observer_response (Wire.observer_response_headers after_gap) = Ok (Some after_gap))
;;

let test_missing_or_malformed_response () =
  check bool "absent capability is explicitly unavailable" true
    (Wire.decode_observer_response [] = Ok None);
  List.iter
    (fun headers ->
      check bool "partial or unknown metadata cannot claim replay" true
        (Result.is_error (Wire.decode_observer_response headers)))
    [ [ "x-masc-sse-instance-id", "instance-a" ]
    ; [ "x-masc-sse-instance-id", ""; "x-masc-sse-replay", "resumed" ]
    ; [ "x-masc-sse-instance-id", "instance-a"; "x-masc-sse-replay", "complete" ]
    ; [ "x-masc-sse-instance-id", "instance-a"; "x-masc-sse-replay", "resumed-after-gap" ]
    ; [ "x-masc-sse-instance-id", "instance-a"; "x-masc-sse-replay", "resumed-after-gap"
      ; "x-masc-sse-replay-missed-through", "0" ]
    ; [ "x-masc-sse-instance-id", "instance-a"; "x-masc-sse-replay", "resumed-after-gap"
      ; "x-masc-sse-replay-missed-through", "forty" ]
    ]
;;

(* A frame written from an object joined out of encoded fields is the frame of
   the whole value, byte for byte: escapes, floats, nesting and non-ASCII text
   included. *)
let test_an_encoded_frame_is_the_frame_of_its_value () =
  let fields =
    [ "type", `String "operator_snapshot"
    ; ( "payload"
      , `Assoc
          [ "quote", `String "a \"b\"\n\\c \xc3\xa9"
          ; "items", `List [ `Int 1; `Float 2.5; `Null; `Bool true; `Assoc [] ]
          ] )
    ; "ts_unix", `Float 1789498400.123
    ]
  in
  let encoded =
    Wire.encoded_object (List.map (fun (key, value) -> key, Wire.encode_json value) fields)
  in
  check string "the frame" (Wire.format_event_yojson ~id:7 ~event_type:"message" (`Assoc fields))
    (Wire.format_event_encoded ~id:7 ~event_type:"message" encoded);
  check bool "the value" true (Yojson.Safe.equal (`Assoc fields) encoded.Wire.json)
;;

let () =
  run "observer epoch continuity"
    [ "reconnect",
      [ test_case "same process replays actual disconnected tool I/O" `Quick
          test_same_instance_replays_disconnected_tool_result
      ; test_case "restart cannot suppress lower live IDs" `Quick
          (fun () ->
            test_unusable_epoch_cannot_suppress_new_live Wire.Instance_changed
              [ "x-masc-sse-instance-id", "instance-old" ])
      ; test_case "unscoped cursor cannot suppress live IDs" `Quick
          (fun () -> test_unusable_epoch_cannot_suppress_new_live Wire.Unscoped_cursor [])
      ; test_case "missing capability differs from invalid metadata" `Quick
          test_missing_or_malformed_response
      ]
    ; "replay gap",
      [ test_case "an event dropped by count is a gap" `Quick test_count_eviction_is_a_gap
      ; test_case "an event dropped by age is a gap" `Quick test_age_eviction_is_a_gap
      ; test_case "a gap reaches the observer headers" `Quick
          test_a_gap_reaches_the_observer_headers
      ]
    ; "wire",
      [ test_case "an encoded frame is the frame of its value" `Quick
          test_an_encoded_frame_is_the_frame_of_its_value
      ]
    ]
;;

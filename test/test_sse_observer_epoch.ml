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
        Sse.get_events_after_for_session ~session_id ~kind:Sse.Observer event_id
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
    ]
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
    ]
;;

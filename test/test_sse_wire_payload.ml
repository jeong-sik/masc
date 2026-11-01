open Alcotest

let test_completed_payloads () =
  List.iter (fun newline ->
    let stream = "\239\187\191" ^ String.concat newline
      [ ": comment"; "id: 7"; "event: message"; "data:one"; "data: two"; "";
        "data"; ""; "data:"; "data:"; "";
        "data:unfinished"; "" ] in
    check (list string) "complete events, no EOF dispatch" [ "one\ntwo"; ""; "\n" ]
      (Sse_wire.data_payloads_of_stream stream)) [ "\n"; "\r\n"; "\r" ]

let test_payload_framing_roundtrip () =
  List.iter (fun payload ->
    check (list string) "formatter/parser preserve payload" [payload]
      (Sse_wire.format_event ~id:3 ~event_type:"message" payload
       |> Sse_wire.data_payloads_of_stream)) [ ""; "hello"; "one\ntwo"; "one\n" ]

let test_fields_are_literal () =
  check (list string) "no leading-whitespace or case normalization" [ " value" ]
    (Sse_wire.data_payloads_of_stream
       " data:ignored\nData:ignored\ndata:  value\n\n");
  check (option string) "bare field" (Some "") (Sse_wire.data_payload_line "data\r");
  check (option string) "optional colon space" (Some "value")
    (Sse_wire.data_payload_line "data:value\r")

let test_observer_replay_headers () =
  let open Sse_wire in
  let ordinary = { instance_id = "process-a"; replay = Resumed } in
  check bool "valid metadata round trips" true
    (decode_observer_response (observer_response_headers ordinary) = Ok (Some ordinary));
  check bool "an old peer without metadata remains distinguishable" true
    (decode_observer_response [] = Ok None);
  List.iter (fun headers ->
    check bool "ambiguous or contradictory metadata is rejected" true
      (Result.is_error (decode_observer_response headers)))
    [ [ "x-masc-sse-instance-id", "process-a"; "X-Masc-Sse-Instance-Id", "process-a"
      ; "x-masc-sse-replay", "resumed" ]
    ; [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "resumed"
      ; "X-Masc-Sse-Replay", "fresh" ]
    ; [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "resumed-after-gap"
      ; "x-masc-sse-replay-missed-through", "41"; "X-Masc-Sse-Replay-Missed-Through", "41" ]
    ; [ "x-masc-sse-replay-missed-through", "41" ]
    ; [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "resumed"
      ; "x-masc-sse-replay-missed-through", "41" ]
    ; [ "x-masc-sse-instance-id", "  "; "x-masc-sse-replay", "fresh" ]
    ; [ "x-masc-sse-instance-id", "process-a, process-b"; "x-masc-sse-replay", "fresh" ]
    ];
  let handshake, cursor = negotiate_observer ~instance_id:"process-a"
      ~headers:[ "x-masc-sse-instance-id", "process-a"; "X-Masc-Sse-Instance-Id", "process-a" ]
      ~last_event_id:(Some 50) in
  check bool "duplicate request instance discards its cursor" true
    (handshake.replay = Reset Unscoped_cursor && cursor = None);
  let resumed = observer_response_headers ordinary in
  let requested = Some { instance_id = "process-a"; event_id = 50 } in
  check bool "a matching requested cursor can resume" true
    (validate_observer_response ~cursor:requested resumed = Ok (Some ordinary));
  check bool "a fresh request cannot be answered as resumed" true
    (Result.is_error (validate_observer_response ~cursor:None resumed));
  check bool "another process cannot resume this cursor" true
    (Result.is_error (validate_observer_response
      ~cursor:(Some { instance_id = "process-b"; event_id = 50 }) resumed));
  check bool "a cursor cannot be sent to a peer without replay metadata" true
    (Result.is_error (validate_observer_response ~cursor:requested []));
  let headers instance_id replay = observer_response_headers { instance_id; replay } in
  check bool "fresh is valid without a requested cursor" true
    (Result.is_ok (validate_observer_response ~cursor:None (headers "process-a" Fresh)));
  check bool "fresh cannot discard a requested cursor" true
    (Result.is_error (validate_observer_response ~cursor:requested (headers "process-a" Fresh)));
  check bool "instance reset requires a cursor" true
    (Result.is_error (validate_observer_response ~cursor:None
      (headers "process-b" (Reset Instance_changed))));
  check bool "instance reset requires a different instance" true
    (Result.is_error (validate_observer_response ~cursor:requested
      (headers "process-a" (Reset Instance_changed))));
  check bool "a changed instance can reset the cursor" true
    (Result.is_ok (validate_observer_response ~cursor:requested
      (headers "process-b" (Reset Instance_changed))));
  List.iter (fun cursor ->
    check bool "an unscoped reset contradicts this client's request" true
      (Result.is_error (validate_observer_response ~cursor
        (headers "process-a" (Reset Unscoped_cursor))))) [ None; requested ];
  let gap missed_through =
    observer_response_headers { ordinary with replay = Resumed_after_gap { missed_through } } in
  check bool "a gap must extend past the requested cursor" true
    (Result.is_error (validate_observer_response ~cursor:requested (gap 50)));
  check bool "a later gap is reported" true
    (Result.is_ok (validate_observer_response ~cursor:requested (gap 51)))

let () = run "SSE wire payload"
  [ "wire", [ test_case "complete payloads" `Quick test_completed_payloads;
              test_case "formatter roundtrip" `Quick test_payload_framing_roundtrip;
              test_case "literal fields" `Quick test_fields_are_literal;
              test_case "observer replay headers" `Quick test_observer_replay_headers ] ]

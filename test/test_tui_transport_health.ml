open Alcotest

module Decode = Masc.Tui_decode

let sample ?(ws_listening = true) ?(grpc_listening = true) () =
  Printf.sprintf
    {|{"summary":{"primary_path":"websocket","queue_pressure":"steady","external_fanout_targets":1},
       "sse":{"sessions_total":3,"external_subscribers":1},
       "websocket":{"listening":%b,"sessions":1,"mode":"same_origin"},
       "grpc":{"listening":%b,"port":8936,"events_dropped":0}}|}
    ws_listening grpc_listening
  |> Yojson.Safe.from_string

let decoded json =
  match Decode.decode_transport_health json with
  | Ok health -> health
  | Error detail -> failf "expected a decode, got: %s" detail

let test_a_listening_transport_reports_its_sessions_and_port () =
  let health = decoded (sample ()) in
  check bool "primary path" true
    (health.Decode.th_primary_path = Masc.Transport_metrics.Websocket);
  check bool "queue pressure" true
    (health.Decode.th_queue_pressure = Masc.Transport_metrics.Steady);
  check int "sse sessions" 3 health.Decode.th_sse_sessions;
  check (option int) "websocket sessions" (Some 1)
    health.Decode.th_websocket_sessions;
  check (option int) "grpc port" (Some 8936) health.Decode.th_grpc_port;
  check int "dropped events" 0 health.Decode.th_events_dropped

let test_a_silent_transport_reports_nothing_rather_than_zero () =
  let health = decoded (sample ~ws_listening:false ~grpc_listening:false ()) in
  (* Zero sessions on a listening socket and a socket that is not listening are
     different facts; the decode must not flatten one into the other. *)
  check (option int) "websocket that is not listening has no session count" None
    health.Decode.th_websocket_sessions;
  check (option int) "grpc that is not listening has no port" None
    health.Decode.th_grpc_port

let test_a_missing_section_is_an_error_not_an_empty_summary () =
  let without_sse =
    Yojson.Safe.from_string
      {|{"summary":{"primary_path":"websocket","queue_pressure":"steady"},
         "websocket":{"listening":false},
         "grpc":{"listening":false,"events_dropped":0}}|}
  in
  match Decode.decode_transport_health without_sse with
  | Ok _ -> fail "a response without the sse section must not decode"
  | Error detail ->
    check bool "names the missing section" true
      (Astring.String.is_infix ~affix:"sse" detail)

let test_a_dropped_event_count_survives_the_decode () =
  let dropping =
    Yojson.Safe.from_string
      (* "backed_up" was never a word this producer emits — the vocabulary is
         steady / watch / high. While the field was a string the fixture and
         the assertion agreed with each other and with nothing else. *)
      {|{"summary":{"primary_path":"sse","queue_pressure":"high"},
         "sse":{"sessions_total":0},
         "websocket":{"listening":false},
         "grpc":{"listening":true,"port":8936,"events_dropped":17}}|}
  in
  let health = decoded dropping in
  check int "dropped events are carried through" 17
    health.Decode.th_events_dropped;
  check bool "a backed up queue is reported as such" true
    (health.Decode.th_queue_pressure = Masc.Transport_metrics.High)

let () =
  run "transport_health"
    [ ( "decode",
        [ test_case "a listening transport reports its sessions and port" `Quick
            test_a_listening_transport_reports_its_sessions_and_port
        ; test_case "a silent transport reports nothing rather than zero" `Quick
            test_a_silent_transport_reports_nothing_rather_than_zero
        ; test_case "a missing section is an error not an empty summary" `Quick
            test_a_missing_section_is_an_error_not_an_empty_summary
        ; test_case "a dropped event count survives the decode" `Quick
            test_a_dropped_event_count_survives_the_decode
        ] )
    ]

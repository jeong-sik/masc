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

let () = run "SSE wire payload"
  [ "wire", [ test_case "complete payloads" `Quick test_completed_payloads;
              test_case "formatter roundtrip" `Quick test_payload_framing_roundtrip;
              test_case "literal fields" `Quick test_fields_are_literal ] ]

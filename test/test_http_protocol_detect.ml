(** Unit tests for Http_protocol_detect.

    [detect_from_fd] was removed; only [protocol_to_string] remains tested. *)

open Masc_mcp

let test_protocol_to_string () =
  Alcotest.(check string) "Http1 label"
    "HTTP/1.1"
    (Http_protocol_detect.protocol_to_string Http_protocol_detect.Http1);
  Alcotest.(check string) "Http2 label"
    "HTTP/2"
    (Http_protocol_detect.protocol_to_string Http_protocol_detect.Http2)

let () =
  Alcotest.run "http_protocol_detect"
    [
      ( "labels",
        [
          Alcotest.test_case "protocol_to_string" `Quick
            test_protocol_to_string;
        ] );
    ]

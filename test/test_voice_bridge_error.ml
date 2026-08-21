(** Voice MCP errors remain typed and render stable operator-facing details.
    The bridge makes one endpoint attempt and exposes the observation; no
    constructor is promoted into an implicit replay policy. *)

module Voice = Masc.Voice_bridge
open Alcotest

let test_rendering_is_stable () =
  check string "timeout" "Request timeout after 30.0s"
    (Voice.mcp_call_error_to_string (Voice.Timed_out 30.0));
  check string "connection" "Connection error: econnrefused"
    (Voice.mcp_call_error_to_string (Voice.Connection_failed "econnrefused"));
  check string "http" "HTTP 503: unavailable"
    (Voice.mcp_call_error_to_string
       (Voice.Http_status { code = 503; body = "unavailable" }));
  check string "malformed" "Voice MCP: invalid JSON body: unexpected token"
    (Voice.mcp_call_error_to_string (Voice.Malformed_body "unexpected token"))
;;

let () =
  Alcotest.run
    "Voice bridge errors"
    [ "typed observation", [ test_case "rendering is stable" `Quick test_rendering_is_stable ] ]
;;

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

let test_voice_mcp_failures_do_not_authorize_failover () =
  List.iter
    (fun (label, error) ->
       check bool
         label
         true
         (Voice.mcp_call_effect_disposition error = Voice.Remote_effect_unresolved))
    [ "timeout", Voice.Timed_out 30.0
    ; "connection", Voice.Connection_failed "econnrefused"
    ; "http", Voice.Http_status { code = 503; body = "unavailable" }
    ; "malformed", Voice.Malformed_body "unexpected token"
    ]
;;

let () =
  Alcotest.run
    "Voice bridge errors"
    [ ( "typed observation"
      , [ test_case "rendering is stable" `Quick test_rendering_is_stable
        ; test_case
            "failure does not authorize endpoint failover"
            `Quick
            test_voice_mcp_failures_do_not_authorize_failover
        ] )
    ]
;;

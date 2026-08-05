(** Retry policy for Voice MCP calls.

    The policy used to read the rendered error message: [starts_with
    "connection"], [starts_with "timeout"], [Scanf "http %d"]. Every string it
    inspected was produced a few lines above by this same module, and one of
    them did not match its own test — [with_timeout] renders "Request timeout
    after 30.0s", which starts with "request". So the loop refused to retry the
    timeouts it had just raised.

    [round_trips_through_the_string_surface] is the case that would have caught
    that: it renders each constructor and asserts the decision survives. *)

module Voice = Masc.Voice_bridge
open Alcotest

let retryable = testable (fun fmt b -> Format.fprintf fmt "%b" b) Bool.equal

let cases =
  [ "timeout", Voice.Timed_out 30.0, true
  ; "connection failure", Voice.Connection_failed "econnrefused", true
  ; "http 500", Voice.Http_status { code = 500; body = "boom" }, true
  ; "http 503", Voice.Http_status { code = 503; body = "unavailable" }, true
  ; "http 400", Voice.Http_status { code = 400; body = "bad request" }, false
  ; "http 404", Voice.Http_status { code = 404; body = "no tool" }, false
  ; "malformed body", Voice.Malformed_body "unexpected token", false
  ]
;;

let test_decides_per_constructor () =
  List.iter
    (fun (label, err, want) ->
      check retryable label want (Voice.is_retryable_error err))
    cases
;;

(* A timeout must be retried however its message happens to read. The old
   predicate failed exactly here. *)
let test_timeout_is_retryable_whatever_it_renders_as () =
  let err = Voice.Timed_out 30.0 in
  let rendered = Voice.mcp_call_error_to_string err in
  check bool "renders without a 'timeout' prefix" true
    (not (String.starts_with ~prefix:"timeout" (String.lowercase_ascii rendered)));
  check retryable "still retryable" true (Voice.is_retryable_error err)
;;

(* Each constructor keeps the wording callers already see. *)
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

(* Server errors retry, client errors do not, across the whole boundary. *)
let test_status_boundary () =
  List.iter
    (fun (code, want) ->
      check retryable
        (Printf.sprintf "http %d" code)
        want
        (Voice.is_retryable_error (Voice.Http_status { code; body = "" })))
    [ 399, false; 400, false; 499, false; 500, true; 599, true; 600, false ]
;;

let () =
  Alcotest.run
    "Voice bridge retry"
    [ ( "policy"
      , [ test_case "decides per constructor" `Quick test_decides_per_constructor
        ; test_case
            "timeout retries whatever it renders as"
            `Quick
            test_timeout_is_retryable_whatever_it_renders_as
        ; test_case "rendering is stable" `Quick test_rendering_is_stable
        ; test_case "5xx retries, 4xx does not" `Quick test_status_boundary
        ] )
    ]
;;

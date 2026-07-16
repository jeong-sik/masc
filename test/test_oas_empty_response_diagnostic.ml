(** OAS Empty Response Diagnostic Harness *)

open Alcotest
module Graphql_client = Masc.Graphql_client

let test_ensure_json_response_empty () =
  let actual = Graphql_client.ensure_json_response "" in
  check (result string string) "empty body" (Error "empty response") actual
;;

let test_ensure_json_response_html () =
  let html_body = "<html><body>Error</body></html>" in
  let actual = Graphql_client.ensure_json_response html_body in
  check
    (result string string)
    "html body"
    (Error "endpoint returned HTML instead of JSON")
    actual
;;

let test_ensure_json_response_json () =
  let json_body = "{\"data\":{\"status\":{\"project\":\"test\"}}}" in
  let actual = Graphql_client.ensure_json_response json_body in
  check (result string string) "json body" (Ok json_body) actual
;;

let test_ensure_json_response_whitespace_json () =
  let json_body = "  {\"data\":null}  " in
  let actual = Graphql_client.ensure_json_response json_body in
  check (result string string) "whitespace then json" (Ok json_body) actual
;;

let test_ensure_json_response_whitespace_html () =
  let html_body = "  <html></html>  " in
  let actual = Graphql_client.ensure_json_response html_body in
  check
    (result string string)
    "whitespace then html"
    (Error "endpoint returned HTML instead of JSON")
    actual
;;

let test_switch_wrong_domain_is_transport_error () =
  let msg = "Invalid_argument(\"Switch accessed from wrong domain!\")" in
  check bool "switch wrong-domain fallback" true
    (Graphql_client.For_testing.is_transport_error msg)
;;

let test_http_status_is_not_transport_error () =
  check bool "http status is application response" false
    (Graphql_client.For_testing.is_transport_error "HTTP 500")
;;

let test_curl_success_preserves_json_body () =
  let body = "{\"data\":{\"status\":\"ok\"}}" in
  let actual =
    Graphql_client.For_testing.response_of_curl_process_result
      (Unix.WEXITED 0, body)
  in
  check (result string string) "successful body" (Ok body) actual
;;

let test_curl_timeout_is_not_a_response_body () =
  let diagnostic = "process_eio_error: timeout after 10s" in
  let actual =
    Graphql_client.For_testing.response_of_curl_process_result
      (Unix.WEXITED 124, diagnostic)
  in
  check
    (result string string)
    "typed timeout status"
    (Error ("curl exited 124: " ^ diagnostic))
    actual
;;

let test_curl_exit_failure_is_not_a_response_body () =
  let output = "{\"data\":{\"stale\":true}}" in
  let actual =
    Graphql_client.For_testing.response_of_curl_process_result
      (Unix.WEXITED 7, output)
  in
  check
    (result string string)
    "typed nonzero exit"
    (Error ("curl exited 7: " ^ output))
    actual
;;

let test_curl_signal_failure_preserves_diagnostic () =
  let diagnostic = "curl: connection reset during shutdown" in
  let actual =
    Graphql_client.For_testing.response_of_curl_process_result
      (Unix.WSIGNALED 15, diagnostic)
  in
  check
    (result string string)
    "typed signal status"
    (Error ("curl signaled 15: " ^ diagnostic))
    actual
;;

let test_curl_stopped_failure_preserves_diagnostic () =
  let diagnostic = "curl: process stopped" in
  let actual =
    Graphql_client.For_testing.response_of_curl_process_result
      (Unix.WSTOPPED 19, diagnostic)
  in
  check
    (result string string)
    "typed stopped status"
    (Error ("curl stopped 19: " ^ diagnostic))
    actual
;;

let () =
  run
    "OAS_empty_response_diagnostic"
    [ ( "ensure_json_response"
      , [ test_case "empty body" `Quick test_ensure_json_response_empty
        ; test_case "html body" `Quick test_ensure_json_response_html
        ; test_case "json body" `Quick test_ensure_json_response_json
        ; test_case "whitespace json" `Quick test_ensure_json_response_whitespace_json
        ; test_case "whitespace html" `Quick test_ensure_json_response_whitespace_html
        ] )
    ; ( "transport_error"
      , [ test_case "switch wrong-domain" `Quick test_switch_wrong_domain_is_transport_error
        ; test_case "http status" `Quick test_http_status_is_not_transport_error
        ] )
    ; ( "curl_process_result"
      , [ test_case "success preserves JSON" `Quick test_curl_success_preserves_json_body
        ; test_case "timeout is failure" `Quick test_curl_timeout_is_not_a_response_body
        ; test_case "nonzero exit is failure" `Quick test_curl_exit_failure_is_not_a_response_body
        ; test_case "signal preserves diagnostic" `Quick
            test_curl_signal_failure_preserves_diagnostic
        ; test_case "stopped preserves diagnostic" `Quick
            test_curl_stopped_failure_preserves_diagnostic
        ] )
    ]
;;

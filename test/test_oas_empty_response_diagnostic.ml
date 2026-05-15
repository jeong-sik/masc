(** OAS Empty Response Diagnostic Harness *)

open Alcotest
module Graphql_client = Masc_mcp.Graphql_client

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
    ]
;;

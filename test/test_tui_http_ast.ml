open Alcotest

let test_is_success_http_status_called () =
  let n =
    Ast_grep.count_calls
      ~module_path:"bin/masc_tui_http.ml"
      ~callee:"Masc.Tui_decode.is_success_http_status"
  in
  if n < 4 then
    failf
      "bin/masc_tui_http.ml must call Masc.Tui_decode.is_success_http_status >= 4 (http_get, http_post, post_raw_json, server_reachable); got %d"
      n
;;

let test_http_get_uses_auth_headers () =
  let n =
    Ast_grep.count_calls
      ~module_path:"bin/masc_tui_http.ml"
      ~callee:"auth_headers"
  in
  if n < 3 then
    failf
      "bin/masc_tui_http.ml must call auth_headers >= 3; got %d"
      n
;;

let () =
  run "masc-tui-http-regression" [
    ( "tui-http",
      [
        test_case "check success status" `Quick test_is_success_http_status_called;
        test_case "auth headers used" `Quick test_http_get_uses_auth_headers;
      ]
    )
  ]

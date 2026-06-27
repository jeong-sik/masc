open Alcotest

let test_is_success_http_status_called () =
  let n =
    Ast_grep.count_calls
      ~module_path:"bin/masc_tui_http.ml"
      ~callee:"Masc.Tui_decode.is_success_http_status"
  in
  if n < 1 then
    failf
      "bin/masc_tui_http.ml must call Masc.Tui_decode.is_success_http_status for raw body responses; got %d"
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

let test_planning_constructors_do_not_collide () =
  let module_path = "bin/masc_tui_types.ml" in
  let workspace_constructors =
    Ast_grep.constructor_names_of_type
      ~module_path
      ~type_name:"workspace_section"
  in
  let surface_constructors =
    Ast_grep.constructor_names_of_type ~module_path ~type_name:"surface"
  in
  check bool "workspace section renamed Planning constructor" false
    (List.mem "Planning" workspace_constructors);
  check bool "workspace planning constructor explicit" true
    (List.mem "Workspace_planning" workspace_constructors);
  check bool "top-level Planning surface remains" true
    (List.mem "Planning" surface_constructors)
;;

let () =
  run "masc-tui-http-regression" [
    ( "tui-http",
      [
        test_case "check success status" `Quick test_is_success_http_status_called;
        test_case "auth headers used" `Quick test_http_get_uses_auth_headers;
        test_case
          "planning constructors do not collide"
          `Quick
          test_planning_constructors_do_not_collide;
      ]
    )
  ]

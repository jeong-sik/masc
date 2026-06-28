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

let test_http_client_does_not_own_tui_env_contract () =
  let module_path = "bin/masc_tui_http.ml" in
  check int "no local TUI env literals" 0
    (Ast_grep.count_string_literals ~module_path ~needle:"MASC_TUI_");
  check int "no ambient agent env fallback" 0
    (Ast_grep.count_string_literals ~module_path ~needle:"MASC_AGENT");
  check int "no local timeout env accessor" 0
    (Ast_grep.count_calls ~module_path ~callee:"Env_config_core.get_float_nonneg");
  check int "no local timeout env binding" 0
    (Ast_grep.count_value_bindings ~module_path ~name:"timeout_env")
;;

let test_planning_constructors_do_not_collide () =
  let module_path = "bin/masc_tui_types.ml" in
  let planning_mode_constructors =
    Ast_grep.constructor_names_of_type ~module_path ~type_name:"planning_mode"
  in
  let surface_constructors =
    Ast_grep.constructor_names_of_type ~module_path ~type_name:"surface"
  in
  check bool "planning sub-mode does not reuse top-level Planning" false
    (List.mem "Planning" planning_mode_constructors);
  check bool "planning list sub-mode explicit" true
    (List.mem "Planning_list" planning_mode_constructors);
  check bool "planning detail sub-mode explicit" true
    (List.mem "Planning_detail" planning_mode_constructors);
  check bool "top-level Planning surface remains" true
    (List.mem "Planning" surface_constructors)
;;

let test_planning_status_is_closed_sum () =
  let constructors =
    Ast_grep.constructor_names_of_type
      ~module_path:"bin/masc_tui_types.ml"
      ~type_name:"planning_goal_status"
  in
  check (list string) "planning status constructors"
    [
      "Planning_goal_active";
      "Planning_goal_paused";
      "Planning_goal_done";
      "Planning_goal_dropped";
    ]
    constructors;
  check int "renderer does not lowercase planning status strings" 0
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"String.lowercase_ascii");
  check int "loader has an explicit unknown-status decode error" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"unknown planning goal status")
;;

let test_overview_state_domains_are_closed_sum () =
  let workspace_health_constructors =
    Ast_grep.constructor_names_of_type
      ~module_path:"bin/masc_tui_types.ml"
      ~type_name:"workspace_health"
  in
  let attention_severity_constructors =
    Ast_grep.constructor_names_of_type
      ~module_path:"bin/masc_tui_types.ml"
      ~type_name:"attention_severity"
  in
  check (list string) "workspace health constructors"
    [
      "Workspace_health_critical";
      "Workspace_health_bad";
      "Workspace_health_risk";
      "Workspace_health_warning";
      "Workspace_health_degraded";
      "Workspace_health_initializing";
      "Workspace_health_ok";
      "Workspace_health_unknown";
    ]
    workspace_health_constructors;
  check (list string) "attention severity constructors"
    [
      "Attention_critical";
      "Attention_bad";
      "Attention_warning";
      "Attention_info";
    ]
    attention_severity_constructors;
  check int "loader has an explicit unknown health decode error" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"unknown workspace health");
  check int "loader has an explicit unknown severity decode error" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"unknown attention severity")
;;

let test_planning_cursor_uses_visible_goal_order () =
  check int "visible planning helper lives in shared types" 1
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_types.ml"
       ~name:"planning_visible_goals");
  check int "visible planning helper avoids duplicate-prone insertion helper" 0
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_types.ml"
       ~name:"insert_sorted");
  check bool "visible planning helper uses stable depth sort" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_types.ml"
       ~callee:"List.stable_sort"
     >= 1);
  check int "render no longer owns a private tree sorter" 0
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_render.ml"
       ~name:"sort_goals_for_tree");
  check bool "render uses shared visible-goal order" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"planning_visible_goals"
     >= 1);
  check bool "key handling uses shared visible-goal order" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"planning_visible_goals"
     >= 2)
;;

let () =
  run "masc-tui-http-regression" [
    ( "tui-http",
      [
        test_case "check success status" `Quick test_is_success_http_status_called;
        test_case "auth headers used" `Quick test_http_get_uses_auth_headers;
        test_case
          "http client does not own TUI env contract"
          `Quick
          test_http_client_does_not_own_tui_env_contract;
        test_case
          "planning constructors do not collide"
          `Quick
          test_planning_constructors_do_not_collide;
        test_case
          "planning status is closed-sum"
          `Quick
          test_planning_status_is_closed_sum;
        test_case
          "overview state domains are closed-sum"
          `Quick
          test_overview_state_domains_are_closed_sum;
        test_case
          "planning cursor uses visible goal order"
          `Quick
          test_planning_cursor_uses_visible_goal_order;
      ]
    )
  ]

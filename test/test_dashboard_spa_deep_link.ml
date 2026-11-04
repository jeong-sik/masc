(* A /dashboard/ path that no route owns is answered with the SPA shell. The
   predicate decides which paths those are. *)

let check_deep_link name expected path =
  Alcotest.(check bool)
    name
    expected
    (Server_routes_http_runtime.is_dashboard_spa_deep_link path)
;;

let test_views_are_deep_links () =
  check_deep_link "nested view" true "/dashboard/command/operations";
  check_deep_link "single segment view" true "/dashboard/monitoring"
;;

let test_assets_have_their_own_handler () =
  check_deep_link "asset file" false "/dashboard/assets/index.css"
;;

let test_other_prefixes_are_not_deep_links () =
  check_deep_link "dashboard index has its own route" false "/dashboard";
  check_deep_link "api path" false "/api/v1/dashboard/goals"
;;

let () =
  Alcotest.run
    "dashboard spa deep link"
    [ ( "is_dashboard_spa_deep_link"
      , [ Alcotest.test_case "views are deep links" `Quick test_views_are_deep_links
        ; Alcotest.test_case
            "assets have their own handler"
            `Quick
            test_assets_have_their_own_handler
        ; Alcotest.test_case
            "other prefixes are not deep links"
            `Quick
            test_other_prefixes_are_not_deep_links
        ] )
    ]
;;

(** Query contract for the fleet Keeper efficiency route. The aggregation
    itself is [test_keeper_efficiency]; this pins how the route reads the
    month and what shape it names. *)

open Alcotest

let req target = Httpun.Request.create `GET target

let month_tests =
  [ ( "a missing or blank month answers the wall clock's current month"
    , `Quick
    , fun () ->
      let expect_current target =
        let got = Server_dashboard_http_keeper_efficiency.month_parameter (req target) in
        let t = Unix.gmtime (Unix.time ()) in
        let current = Printf.sprintf "%04d-%02d" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) in
        check string target current got
      in
      expect_current Server_dashboard_http_keeper_efficiency.route_path;
      expect_current (Server_dashboard_http_keeper_efficiency.route_path ^ "?month=");
      expect_current (Server_dashboard_http_keeper_efficiency.route_path ^ "?month=%20") )
  ; ( "an explicit month is passed through trimmed"
    , `Quick
    , fun () ->
      check string "explicit month" "2026-09"
        (Server_dashboard_http_keeper_efficiency.month_parameter
           (req (Server_dashboard_http_keeper_efficiency.route_path ^ "?month=%202026-09%20")));
      check string "unrelated params ignored" "2026-10"
        (Server_dashboard_http_keeper_efficiency.month_parameter
           (req (Server_dashboard_http_keeper_efficiency.route_path ^ "?x=1&month=2026-10"))) )
  ; ( "the route path and response schema names are the contract"
    , `Quick
    , fun () ->
      check string "route path" "/api/v1/keeper-efficiency"
        Server_dashboard_http_keeper_efficiency.route_path )
  ; ( "active_only query parameter parses strictly"
    , `Quick
    , fun () ->
      let check_ok label expected target =
        check (result bool string) label (Ok expected)
          (Server_dashboard_http_keeper_efficiency.active_only_parameter (req target))
      in
      let base = Server_dashboard_http_keeper_efficiency.route_path in
      check_ok "absent defaults false" false base;
      check_ok "blank defaults false" false (base ^ "?active_only=");
      check_ok "false is false" false (base ^ "?active_only=false");
      check_ok "true is true" true (base ^ "?active_only=true");
      check_ok "1 is true" true (base ^ "?active_only=1");
      check bool "invalid active_only rejected" true
        (Result.is_error
           (Server_dashboard_http_keeper_efficiency.active_only_parameter
              (req (base ^ "?active_only=maybe")))) )
  ]

let () = run "Keeper_efficiency_route" [ ("month", month_tests) ]

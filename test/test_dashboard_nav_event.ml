open Alcotest
open Masc_mcp

let parse_ok json_str =
  match Dashboard_nav_event.parse_event_json (Yojson.Safe.from_string json_str) with
  | Ok event -> event
  | Error msg -> failf "expected Ok, got Error %s" msg
;;

let parse_err json_str =
  match Dashboard_nav_event.parse_event_json (Yojson.Safe.from_string json_str) with
  | Ok _ -> fail "expected Error, got Ok"
  | Error msg -> msg
;;

let test_parse_minimal_surface_only () =
  let event = parse_ok {|{"surface":"overview"}|} in
  check string "surface" "overview" event.surface;
  check (option string) "section" None event.section;
  check (option string) "redirected_from" None event.redirected_from
;;

let test_parse_full_event () =
  let event =
    parse_ok {|{"surface":"monitoring","section":"journey","redirected_from":"none"}|}
  in
  check string "surface" "monitoring" event.surface;
  check (option string) "section" (Some "journey") event.section;
  check (option string) "redirected_from" None event.redirected_from
;;

let test_parse_redirected () =
  let event =
    parse_ok
      {|{"surface":"workspace","section":"repositories","redirected_from":"monitoring:git-graph"}|}
  in
  check
    (option string)
    "redirected_from"
    (Some "monitoring:git-graph")
    event.redirected_from
;;

let test_reject_unknown_surface () =
  let msg = parse_err {|{"surface":"bogus"}|} in
  check
    bool
    "mentions surface"
    true
    (Astring.String.is_infix ~affix:"unknown surface" msg)
;;

let test_reject_unknown_section () =
  let msg = parse_err {|{"surface":"monitoring","section":"ferris-wheel"}|} in
  check
    bool
    "mentions section"
    true
    (Astring.String.is_infix ~affix:"unknown section" msg)
;;

let test_reject_redirected_from_unknown_surface () =
  let msg =
    parse_err
      {|{"surface":"workspace","section":"repositories","redirected_from":"bogus:foo"}|}
  in
  check
    bool
    "mentions redirected_from"
    true
    (Astring.String.is_infix ~affix:"redirected_from" msg)
;;

let test_reject_redirected_from_self () =
  let msg =
    parse_err
      {|{"surface":"workspace","section":"repositories","redirected_from":"workspace:repositories"}|}
  in
  check bool "mentions self" true (Astring.String.is_infix ~affix:"differ" msg)
;;

let test_reject_missing_surface () =
  let msg = parse_err {|{"section":"journey"}|} in
  check bool "mentions surface" true (Astring.String.is_infix ~affix:"surface" msg)
;;

let test_reject_malformed_json () =
  let msg = parse_err "not json {" in
  check bool "non-empty error" true (String.length msg > 0)
;;

let test_section_null_explicit () =
  let event = parse_ok {|{"surface":"cockpit","section":null}|} in
  check (option string) "section" None event.section
;;

let test_record_increments_surface_counter () =
  let before =
    Prometheus.get_metric_value
      "dashboard_surface_open_total"
      ~labels:[ "surface", "overview" ]
      ()
    |> Option.value ~default:0.0
  in
  Dashboard_nav_event.record
    { surface = "overview"; section = None; redirected_from = None };
  let after =
    Prometheus.get_metric_value
      "dashboard_surface_open_total"
      ~labels:[ "surface", "overview" ]
      ()
    |> Option.value ~default:0.0
  in
  check (float 1e-9) "incremented by 1" 1.0 (after -. before)
;;

let test_record_increments_section_counter_with_redirect_label () =
  let labels =
    [ "surface", "workspace"
    ; "section", "repositories"
    ; "redirected_from", "monitoring:git-graph"
    ]
  in
  let before =
    Prometheus.get_metric_value "dashboard_section_open_total" ~labels ()
    |> Option.value ~default:0.0
  in
  Dashboard_nav_event.record
    { surface = "workspace"
    ; section = Some "repositories"
    ; redirected_from = Some "monitoring:git-graph"
    };
  let after =
    Prometheus.get_metric_value "dashboard_section_open_total" ~labels ()
    |> Option.value ~default:0.0
  in
  check (float 1e-9) "incremented by 1" 1.0 (after -. before)
;;

let test_record_section_counter_redirect_none_label () =
  let labels = [ "surface", "lab"; "section", "tools"; "redirected_from", "none" ] in
  let before =
    Prometheus.get_metric_value "dashboard_section_open_total" ~labels ()
    |> Option.value ~default:0.0
  in
  Dashboard_nav_event.record
    { surface = "lab"; section = Some "tools"; redirected_from = None };
  let after =
    Prometheus.get_metric_value "dashboard_section_open_total" ~labels ()
    |> Option.value ~default:0.0
  in
  check (float 1e-9) "incremented by 1 with 'none' label" 1.0 (after -. before)
;;

let () =
  Alcotest.run
    "dashboard_nav_event"
    [ ( "parse_event_json"
      , [ test_case "minimal surface only" `Quick test_parse_minimal_surface_only
        ; test_case "full event" `Quick test_parse_full_event
        ; test_case "redirected_from accepted" `Quick test_parse_redirected
        ; test_case "rejects unknown surface" `Quick test_reject_unknown_surface
        ; test_case "rejects unknown section" `Quick test_reject_unknown_section
        ; test_case
            "rejects redirected_from unknown surface"
            `Quick
            test_reject_redirected_from_unknown_surface
        ; test_case
            "rejects redirected_from = self"
            `Quick
            test_reject_redirected_from_self
        ; test_case "rejects missing surface" `Quick test_reject_missing_surface
        ; test_case "rejects malformed json" `Quick test_reject_malformed_json
        ; test_case "explicit null section" `Quick test_section_null_explicit
        ] )
    ; ( "record"
      , [ test_case
            "increments surface counter"
            `Quick
            test_record_increments_surface_counter
        ; test_case
            "increments section counter with redirect label"
            `Quick
            test_record_increments_section_counter_with_redirect_label
        ; test_case
            "section counter falls back to 'none' label"
            `Quick
            test_record_section_counter_redirect_none_label
        ] )
    ]
;;

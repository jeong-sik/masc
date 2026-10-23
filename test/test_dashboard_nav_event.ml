open Alcotest
open Masc

let parse_ok json_str =
  match Dashboard_nav_event.parse_event_json (Yojson.Safe.from_string json_str) with
  | Ok event -> event
  | Error msg -> failf "expected Ok, got Error %s" msg
;;

let parse_err json_str =
  match Yojson.Safe.from_string json_str with
  | exception Yojson.Json_error msg -> msg
  | json ->
    (match Dashboard_nav_event.parse_event_json json with
     | Ok _ -> fail "expected Error, got Ok"
     | Error msg -> msg)
;;

let test_parse_minimal_surface_only () =
  let event = parse_ok {|{"surface":"overview"}|} in
  check string "surface" "overview" event.surface;
  check (option string) "section" None event.section
;;

let test_parse_schedule_surface_only () =
  let event = parse_ok {|{"surface":"schedule"}|} in
  check string "surface" "schedule" event.surface;
  check (option string) "section" None event.section
;;

let test_parse_settings_runtime_section () =
  let event = parse_ok {|{"surface":"settings","section":"runtime"}|} in
  check string "surface" "settings" event.surface;
  check (option string) "section" (Some "runtime") event.section
;;

let test_parse_settings_account_section () =
  let event = parse_ok {|{"surface":"settings","section":"account"}|} in
  check (option string) "section" (Some "account") event.section
;;

let test_parse_settings_routing_section () =
  let event = parse_ok {|{"surface":"settings","section":"routing"}|} in
  check string "surface" "settings" event.surface;
  check (option string) "section" (Some "routing") event.section
;;

let test_parse_settings_repositories_section () =
  let event = parse_ok {|{"surface":"settings","section":"repositories"}|} in
  check string "surface" "settings" event.surface;
  check (option string) "section" (Some "repositories") event.section
;;

let test_parse_full_event () =
  let event =
    parse_ok {|{"surface":"monitoring","section":"agents"}|}
  in
  check string "surface" "monitoring" event.surface;
  check (option string) "section" (Some "agents") event.section
;;

let test_parse_current_section_targets () =
  List.iter
    (fun (surface, section) ->
       let json = `Assoc [ "surface", `String surface; "section", `String section ] in
       match Dashboard_nav_event.parse_event_json json with
       | Error msg -> failf "current route %s:%s rejected: %s" surface section msg
       | Ok event -> check (option string) "section" (Some section) event.section)
    [ "monitoring", "lane-inventory"; "workspace", "artifacts" ]
;;

let test_parse_internal_agents_section () =
  let event =
    parse_ok {|{"surface":"monitoring","section":"internal-agents"}|}
  in
  check string "surface" "monitoring" event.surface;
  check (option string) "section" (Some "internal-agents") event.section
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

let test_reject_missing_surface () =
  let msg = parse_err {|{"section":"journey"}|} in
  check bool "mentions surface" true (Astring.String.is_infix ~affix:"surface" msg)
;;

let test_reject_malformed_json () =
  let msg = parse_err "not json {" in
  check bool "non-empty error" true (String.length msg > 0)
;;

let test_section_null_explicit () =
  let event = parse_ok {|{"surface":"overview","section":null}|} in
  check (option string) "section" None event.section
;;

let test_record_increments_surface_counter () =
  let before =
    Otel_metric_store.get_metric_value
      "dashboard_surface_open_total"
      ~labels:[ "surface", "overview" ]
      ()
    |> Option.value ~default:0.0
  in
  Dashboard_nav_event.record
    { surface = "overview"; section = None };
  let after =
    Otel_metric_store.get_metric_value
      "dashboard_surface_open_total"
      ~labels:[ "surface", "overview" ]
      ()
    |> Option.value ~default:0.0
  in
  check (float 1e-9) "incremented by 1" 1.0 (after -. before)
;;

let test_record_increments_section_counter () =
  let labels =
    [ "surface", "workspace"
    ; "section", "repositories"
    ]
  in
  let before =
    Otel_metric_store.get_metric_value "dashboard_section_open_total" ~labels ()
    |> Option.value ~default:0.0
  in
  Dashboard_nav_event.record
    { surface = "workspace"
    ; section = Some "repositories"
    };
  let after =
    Otel_metric_store.get_metric_value "dashboard_section_open_total" ~labels ()
    |> Option.value ~default:0.0
  in
  check (float 1e-9) "incremented by 1" 1.0 (after -. before)
;;

let () =
  Alcotest.run
    "dashboard_nav_event"
    [ ( "parse_event_json"
      , [ test_case "minimal surface only" `Quick test_parse_minimal_surface_only
        ; test_case "schedule surface only" `Quick test_parse_schedule_surface_only
        ; test_case "settings runtime section" `Quick test_parse_settings_runtime_section
        ; test_case
            "settings account section"
            `Quick
            test_parse_settings_account_section
        ; test_case
            "settings routing section"
            `Quick
            test_parse_settings_routing_section
        ; test_case
            "settings repositories section"
            `Quick
            test_parse_settings_repositories_section
        ; test_case "full event" `Quick test_parse_full_event
        ; test_case "current section targets" `Quick test_parse_current_section_targets
        ; test_case
            "internal agents section"
            `Quick
            test_parse_internal_agents_section
        ; test_case "rejects unknown surface" `Quick test_reject_unknown_surface
        ; test_case "rejects unknown section" `Quick test_reject_unknown_section
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
            "increments section counter"
            `Quick
            test_record_increments_section_counter
        ] )
    ]
;;

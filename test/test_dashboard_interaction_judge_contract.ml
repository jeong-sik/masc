let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let check_json_string label expected json =
  match json with
  | Some (`String actual) -> Alcotest.(check string) label expected actual
  | _ -> Alcotest.fail (label ^ ": expected string field")

let check_json_bool label expected json =
  match json with
  | Some (`Bool actual) -> Alcotest.(check bool) label expected actual
  | _ -> Alcotest.fail (label ^ ": expected bool field")

let test_default_surface_is_disabled_and_observable () =
  let json =
    Dashboard_interaction_judge.fresh_interactions_json
      ~base_path:"/tmp/masc-test-dashboard-interaction-judge"
  in
  check_json_bool "enabled" false (json_member "enabled" json);
  check_json_bool "judge_online" false (json_member "judge_online" json);
  check_json_bool "refreshing" false (json_member "refreshing" json);
  check_json_string "status" "disabled" (json_member "status" json);
  check_json_string
    "next_action"
    "migrate_to_fusion_job_lifecycle"
    (json_member "next_action" json);
  match json_member "lifecycle_event" json with
  | Some (`Assoc _ as event) ->
    check_json_string "event caller" "interaction_judge" (json_member "caller" event);
    check_json_string
      "event next_action"
      "migrate_to_fusion_job_lifecycle"
      (json_member "next_action" event)
  | _ -> Alcotest.fail "lifecycle_event: expected object"

let test_parser_reports_schema_errors_without_exception () =
  let invalid =
    `Assoc
      [ "stigmergy", `Assoc [ "board", `String "strong" ]
      ; "interactions", `List [ `Assoc [ "source", `String "board" ] ]
      ]
  in
  match Dashboard_interaction_judge.parse_judge_response invalid with
  | Ok _ -> Alcotest.fail "invalid schema unexpectedly parsed"
  | Error msg ->
    Alcotest.(check bool)
      "schema error names bad field"
      true
      (String.contains msg '.'
       || String.starts_with ~prefix:"interactions" msg
       || String.starts_with ~prefix:"stigmergy" msg)

let () =
  Alcotest.run
    "dashboard_interaction_judge_contract"
    [ ( "surface"
      , [ Alcotest.test_case
            "default surface is disabled and observable"
            `Quick
            test_default_surface_is_disabled_and_observable
        ]
      )
    ; ( "parser"
      , [ Alcotest.test_case
            "parser reports schema errors without exception"
            `Quick
            test_parser_reports_schema_errors_without_exception
        ]
      )
    ]

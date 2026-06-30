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

let check_json_string_list_contains label expected json =
  match json with
  | Some (`List values) ->
    let strings =
      values
      |> List.filter_map (function
           | `String value -> Some value
           | _ -> None)
    in
    Alcotest.(check bool) label true (List.exists (String.equal expected) strings)
  | _ -> Alcotest.fail (label ^ ": expected string list field")

let test_default_surface_is_disabled_and_observable () =
  let next_action = "migrate_to_fusion_job_lifecycle" in
  let json =
    Dashboard_interaction_judge.fresh_interactions_json
      ~base_path:"/tmp/masc-test-dashboard-interaction-judge"
  in
  Alcotest.(check string)
    "typed contract next_action"
    next_action
    Dashboard_interaction_judge.lifecycle_contract.next_action;
  check_json_bool "enabled" false (json_member "enabled" json);
  check_json_bool "judge_online" false (json_member "judge_online" json);
  check_json_bool "refreshing" false (json_member "refreshing" json);
  check_json_string "status" "disabled" (json_member "status" json);
  check_json_string "next_action" next_action (json_member "next_action" json);
  (match json_member "lifecycle_contract" json with
   | Some (`Assoc _ as contract) ->
     check_json_string
       "contract id"
       "dashboard_interaction_judge_fusion_lifecycle"
       (json_member "id" contract);
     check_json_string "contract next_action" next_action (json_member "next_action" contract);
     check_json_string
       "contract issue"
       "https://github.com/jeong-sik/masc/issues/22656"
       (json_member "issue_url" contract);
     check_json_string
       "contract doc"
       "docs/design/dashboard-interaction-judge-fusion-lifecycle.md"
       (json_member "doc_path" contract);
     check_json_string
       "contract route"
       "/api/v1/dashboard/fusion-runs"
       (json_member "fusion_runs_route" contract);
     check_json_string
       "contract sse event"
       "fusion_run_status"
       (json_member "fusion_run_status_event" contract);
     check_json_string_list_contains
       "contract running status"
       "running"
       (json_member "status_labels" contract);
     check_json_string_list_contains
       "contract failed status"
       "failed"
       (json_member "status_labels" contract)
   | _ -> Alcotest.fail "lifecycle_contract: expected object");
  match json_member "lifecycle_event" json with
  | Some (`Assoc _ as event) ->
    check_json_string "event caller" "interaction_judge" (json_member "caller" event);
    check_json_string "event next_action" next_action (json_member "next_action" event);
    check_json_string
      "event contract"
      "dashboard_interaction_judge_fusion_lifecycle"
      (json_member "contract_id" event);
    check_json_string
      "event contract issue"
      "https://github.com/jeong-sik/masc/issues/22656"
      (json_member "contract_issue_url" event)
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

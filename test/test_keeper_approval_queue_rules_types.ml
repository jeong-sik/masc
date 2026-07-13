open Alcotest

module Q = Keeper_approval_queue_rules_types

let yojson = testable Yojson.Safe.pretty_print Yojson.Safe.equal

let sample_rule =
  { Q.id = "rule-1"
  ; keeper_name = "keeper"
  ; tool_name = "external-effect"
  ; request_fingerprint = "abcdef1234567890"
  ; created_at = 1780587600.0
  ; created_by = Some "operator"
  ; source_approval_id = Some "approval-1"
  }
;;

let test_advisory_judgment_round_trip () =
  List.iter
    (fun judgment ->
       let wire = Q.advisory_judgment_to_string judgment in
       check bool wire true (Q.advisory_judgment_of_string wire = Some judgment))
    [ Q.Approve; Q.Deny; Q.Require_human ];
  check (option reject) "unknown" None (Q.advisory_judgment_of_string "unknown")
;;

let test_summary_json_is_nonhierarchical () =
  let summary : Q.hitl_context_summary =
    { summary_version = 2
    ; generated_at = 1780587600.0
    ; model_run_id = "run-1"
    ; context_summary = "The exact action matches the active task."
    ; key_questions = [ "Is the target current?" ]
    ; judgment = Q.Approve
    ; rationale = "The visible evidence supports this exact request."
    }
  in
  let json = Q.hitl_context_summary_to_yojson summary in
  let member name = Yojson.Safe.Util.member name json in
  check yojson "judgment" (`String "approve") (member "judgment");
  check yojson "rationale" (`String summary.rationale) (member "rationale");
  check yojson "no numeric score" `Null (member "score");
  check yojson "no hierarchy" `Null (member "level");
  match
    Q.summary_status_of_yojson_with_error
      (Q.summary_status_to_yojson (Q.Summary_available summary))
  with
  | Error reason -> fail reason
  | Ok (Q.Summary_available parsed) ->
    check bool "judgment persisted" true (parsed.judgment = Q.Approve)
  | Ok (Q.Summary_not_requested | Q.Summary_pending | Q.Summary_failed _) ->
    fail "available summary did not round trip"
;;

let test_approval_rule_json_round_trip () =
  match Q.approval_rule_of_yojson (Q.approval_rule_to_yojson sample_rule) with
  | None -> fail "expected exact approval rule to parse"
  | Some parsed ->
    check string "id" sample_rule.id parsed.id;
    check string "fingerprint" sample_rule.request_fingerprint parsed.request_fingerprint
;;

let without_field field = function
  | `Assoc fields -> `Assoc (List.remove_assoc field fields)
  | json -> json
;;

let test_rule_parser_is_closed_and_explicit () =
  let valid = Q.approval_rule_to_yojson sample_rule in
  check
    (option reject)
    "missing identity"
    None
    (Q.approval_rule_of_yojson (without_field "keeper_name" valid));
  let extended =
    match valid with
    | `Assoc fields -> `Assoc (("classification", `String "legacy") :: fields)
    | json -> json
  in
  match Q.approval_rule_of_yojson_with_error extended with
  | Ok _ -> fail "unsupported persisted fields must require explicit re-approval"
  | Error reason ->
    check
      string
      "failure names unsupported field"
      "approval rule contains unsupported field classification; explicit re-approval is required"
      reason
;;

let test_rule_parser_rejects_duplicate_fields () =
  let duplicated =
    match Q.approval_rule_to_yojson sample_rule with
    | `Assoc fields -> `Assoc (("keeper_name", `String "other") :: fields)
    | json -> json
  in
  match Q.approval_rule_of_yojson_with_error duplicated with
  | Ok _ -> fail "duplicate persisted fields must require explicit re-approval"
  | Error reason ->
    check
      string
      "failure names duplicate field"
      "approval rule contains duplicate field keeper_name; explicit re-approval is required"
      reason
;;

let () =
  run
    "Keeper_approval_queue_rules_types"
    [ ( "judgment"
      , [ test_case "typed judgment round trip" `Quick test_advisory_judgment_round_trip
        ; test_case "summary has no hierarchy" `Quick test_summary_json_is_nonhierarchical
        ] )
    ; ( "exact rule"
      , [ test_case "JSON round trip" `Quick test_approval_rule_json_round_trip
        ; test_case "closed explicit parser" `Quick test_rule_parser_is_closed_and_explicit
        ; test_case
            "duplicate fields rejected"
            `Quick
            test_rule_parser_rejects_duplicate_fields
        ] )
    ]
;;

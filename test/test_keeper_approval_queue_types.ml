open Alcotest

module Q = Keeper_approval_queue_types

let yojson = testable Yojson.Safe.pretty_print Yojson.Safe.equal

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

let () =
  run
    "Keeper_approval_queue_types"
    [ ( "judgment"
      , [ test_case "typed judgment round trip" `Quick test_advisory_judgment_round_trip
        ; test_case "summary has no hierarchy" `Quick test_summary_json_is_nonhierarchical
        ] )
    ]
;;

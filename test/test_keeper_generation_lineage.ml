open Alcotest
module KGL = Masc_mcp.Keeper_generation_lineage

let classify_identity_fields_marks_changed_and_dropped () =
  let inherited, changed, dropped =
    KGL.classify_identity_fields
      ~previous:
        [ "goal", "Keep the system coherent"
        ; "instructions", "Always capture evidence"
        ; "needs", "Operator feedback"
        ]
      ~current:
        [ "goal", "Keep the system coherent"
        ; "instructions", ""
        ; "needs", "Recent telemetry"
        ]
  in
  check (list string) "inherited fields" [ "goal" ] inherited;
  check (list string) "changed fields" [ "needs" ] changed;
  check (list string) "dropped fields" [ "instructions" ] dropped
;;

let continuity_judgment_reports_missing_summary () =
  let judgment =
    KGL.continuity_judgment ~original:"" ~received:"Goal: continue the current task"
  in
  check string "missing summary verdict" "unavailable" judgment.verdict;
  check bool "missing summary similarity absent" true (Option.is_none judgment.similarity)
;;

let continuity_judgment_verifies_identical_summary () =
  let text = "Goal: finish lineage telemetry\nProgress: dashboard panel integrated" in
  let judgment = KGL.continuity_judgment ~original:text ~received:text in
  check string "identical summary verdict" "verified" judgment.verdict;
  check bool "similarity available" true (Option.is_some judgment.similarity)
;;

let () =
  run
    "Keeper_generation_lineage"
    [ ( "identity delta"
      , [ test_case
            "changed and dropped fields are classified"
            `Quick
            classify_identity_fields_marks_changed_and_dropped
        ] )
    ; ( "continuity judgment"
      , [ test_case
            "missing continuity summary reports unavailable"
            `Quick
            continuity_judgment_reports_missing_summary
        ; test_case
            "identical continuity summary verifies"
            `Quick
            continuity_judgment_verifies_identical_summary
        ] )
    ]
;;

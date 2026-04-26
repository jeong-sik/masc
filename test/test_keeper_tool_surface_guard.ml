open Alcotest
module KTD = Masc_mcp.Keeper_tool_disclosure

let test_unexpected_tool_names_accepts_keeper_surface () =
  check
    (list string)
    "no unexpected tools"
    []
    (KTD.unexpected_tool_names
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "extend_turns" ])
;;

let test_unexpected_tool_names_reports_foreign_surface () =
  check
    (list string)
    "foreign tools flagged"
    [ "Skill"; "Bash"; "Agent" ]
    (KTD.unexpected_tool_names
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "Skill"; "Bash"; "Skill"; "Agent" ])
;;

(* #8471 partial tolerance: mixed turn (valid + unexpected) must not
   hard-fail — the valid tool call is real work and should survive. *)
let test_has_valid_tool_call_true_when_mixed () =
  check
    bool
    "mixed turn keeps valid tool call"
    true
    (KTD.has_valid_tool_call
       ~unexpected_tool_names:[ "Bash"; "Skill" ]
       ~tool_names:[ "keeper_task_claim"; "Bash"; "Skill" ])
;;

(* Pure hallucination: every call is outside the surface — no valid
   work in this turn, so keeper_agent_run correctly hard-fails. *)
let test_has_valid_tool_call_false_when_all_unexpected () =
  check
    bool
    "pure hallucination turn has no valid tool"
    false
    (KTD.has_valid_tool_call
       ~unexpected_tool_names:[ "Bash"; "Skill"; "Read" ]
       ~tool_names:[ "Bash"; "Skill"; "Read" ])
;;

(* Empty turn (text-only response, no tool calls): has_valid returns
   false. The caller's outer `unexpected_tool_names <> []` guard still
   prevents this case from being treated as a partial-tolerance success. *)
let test_has_valid_tool_call_false_when_empty () =
  check
    bool
    "empty tool list returns false"
    false
    (KTD.has_valid_tool_call ~unexpected_tool_names:[] ~tool_names:[])
;;

let () =
  run
    "keeper_tool_surface_guard"
    [ ( "surface_guard"
      , [ test_case
            "accepts keeper surface"
            `Quick
            test_unexpected_tool_names_accepts_keeper_surface
        ; test_case
            "reports foreign surface"
            `Quick
            test_unexpected_tool_names_reports_foreign_surface
        ] )
    ; ( "partial_tolerance"
      , [ test_case
            "mixed turn keeps valid call"
            `Quick
            test_has_valid_tool_call_true_when_mixed
        ; test_case
            "pure hallucination has no valid"
            `Quick
            test_has_valid_tool_call_false_when_all_unexpected
        ; test_case
            "empty tool list returns false"
            `Quick
            test_has_valid_tool_call_false_when_empty
        ] )
    ]
;;

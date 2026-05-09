open Alcotest

module KTD = Masc_mcp.Keeper_tool_disclosure

let test_unexpected_tool_names_accepts_keeper_surface () =
  check (list string) "no unexpected tools" []
    (KTD.unexpected_tool_names
       ~allowed_tool_names:
         [ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "extend_turns" ])

let test_unexpected_tool_names_reports_foreign_surface () =
  check (list string) "foreign tools flagged"
    [ "Skill"; "Bash"; "Agent" ]
    (KTD.unexpected_tool_names
       ~allowed_tool_names:
         [ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:
         [ "keeper_task_claim"; "Skill"; "Bash"; "Skill"; "Agent" ])

(* #8471 partial tolerance: mixed turn (valid + unexpected) must not
   hard-fail — the valid tool call is real work and should survive. *)
let test_has_valid_tool_call_true_when_mixed () =
  check bool "mixed turn keeps valid tool call" true
    (KTD.has_valid_tool_call
       ~unexpected_tool_names:[ "Bash"; "Skill" ]
       ~tool_names:[ "keeper_task_claim"; "Bash"; "Skill" ])

(* Pure hallucination: every call is outside the surface — no valid
   work in this turn, so keeper_agent_run correctly hard-fails. *)
let test_has_valid_tool_call_false_when_all_unexpected () =
  check bool "pure hallucination turn has no valid tool" false
    (KTD.has_valid_tool_call
       ~unexpected_tool_names:[ "Bash"; "Skill"; "Read" ]
       ~tool_names:[ "Bash"; "Skill"; "Read" ])

(* Empty turn (text-only response, no tool calls): has_valid returns
   false. The caller's outer `unexpected_tool_names <> []` guard still
   prevents this case from being treated as a partial-tolerance success. *)
let test_has_valid_tool_call_false_when_empty () =
  check bool "empty tool list returns false" false
    (KTD.has_valid_tool_call
       ~unexpected_tool_names:[]
       ~tool_names:[])

(* --- contract_enforcement_filter tests --- *)

(* Use real canonical tool names. Passive_status tools must have
   Tool_catalog.effect_domain = Some Read_only so classify_tool_progress
   classifies them correctly even when Tool_dispatch.read_only_set is
   uninitialised (test environment).  keeper_tasks_list and
   keeper_pr_status both have Read_only effect_domain in Tool_catalog. *)

let passive_tool = "keeper_tasks_list"
let passive_tool_alt = "keeper_pr_status"
let execution_tool = "keeper_task_claim"
let completion_tool = "keeper_stay_silent"
let claim_tool = "masc_claim_next"

let mixed_tools =
  [ passive_tool; execution_tool; completion_tool; claim_tool ]

(* Streak below threshold: no filtering regardless of signal. *)
let test_contract_filter_below_threshold () =
  check (list string) "all tools preserved" mixed_tools
    (KTD.contract_enforcement_filter
       ~passive_streak:2 ~streak_threshold:3 ~actionable_signal:true mixed_tools)

(* At threshold but no actionable signal: no filtering. *)
let test_contract_filter_no_signal () =
  check (list string) "all tools preserved" mixed_tools
    (KTD.contract_enforcement_filter
       ~passive_streak:5 ~streak_threshold:3 ~actionable_signal:false mixed_tools)

(* At threshold WITH actionable signal: passive tools stripped. *)
let test_contract_filter_strips_passive () =
  let filtered =
    KTD.contract_enforcement_filter
      ~passive_streak:5 ~streak_threshold:3 ~actionable_signal:true mixed_tools
  in
  check bool "passive tool removed" false (List.mem passive_tool filtered);
  check bool "execution preserved" true (List.mem execution_tool filtered);
  check bool "completion preserved" true (List.mem completion_tool filtered);
  check bool "claim preserved" true (List.mem claim_tool filtered);
  check int "3 tools remain" 3 (List.length filtered)

(* Only passive tools in input: filter returns empty. *)
let test_contract_filter_all_passive () =
  check (list string) "empty result" []
    (KTD.contract_enforcement_filter
       ~passive_streak:5 ~streak_threshold:3 ~actionable_signal:true
       [ passive_tool; passive_tool_alt ])

(* Empty input: empty output. *)
let test_contract_filter_empty_input () =
  check (list string) "empty in empty out" []
    (KTD.contract_enforcement_filter
       ~passive_streak:5 ~streak_threshold:3 ~actionable_signal:true [])

let () =
  run "keeper_tool_surface_guard"
    [
      ( "surface_guard",
        [
          test_case "accepts keeper surface" `Quick
            test_unexpected_tool_names_accepts_keeper_surface;
          test_case "reports foreign surface" `Quick
            test_unexpected_tool_names_reports_foreign_surface;
        ] );
      ( "partial_tolerance",
        [
          test_case "mixed turn keeps valid call" `Quick
            test_has_valid_tool_call_true_when_mixed;
          test_case "pure hallucination has no valid" `Quick
            test_has_valid_tool_call_false_when_all_unexpected;
          test_case "empty tool list returns false" `Quick
            test_has_valid_tool_call_false_when_empty;
        ] );
      ( "contract_enforcement_filter",
        [
          test_case "below threshold: no filtering" `Quick
            test_contract_filter_below_threshold;
          test_case "no signal: no filtering" `Quick
            test_contract_filter_no_signal;
          test_case "strips passive at threshold with signal" `Quick
            test_contract_filter_strips_passive;
          test_case "all passive: returns empty" `Quick
            test_contract_filter_all_passive;
          test_case "empty input: empty output" `Quick
            test_contract_filter_empty_input;
        ] );
    ]

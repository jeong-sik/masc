(** Pure-function unit tests for [Keeper_contract_classifier].

    Covers ADT label mappers, the [is_actionable] boolean projection,
    [classify_actionable_signal] precedence (unclaimed_tasks >
    board_activity > discovered_work), and the tool-aware variant that
    skips a signal when no matching tool is in the allowed surface. *)

open Masc_mcp
module KCC = Keeper_contract_classifier

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

(* Helper to build a [world_observation] with named fields. *)
let make_obs ~tasks ~board ~discovered : KCC.world_observation =
  {
    unclaimed_task_count = tasks;
    board_activity_count = board;
    has_discovered_work_section = discovered;
  }

let signal_testable : KCC.actionable_signal Alcotest.testable =
  Alcotest.testable
    (fun fmt s -> Format.fprintf fmt "%s" (KCC.actionable_signal_label s))
    ( = )

let check_signal label expected actual =
  Alcotest.check signal_testable label expected actual

(* ── actionable_signal_label ─────────────────────────────────────────── *)

let test_signal_label_unclaimed () =
  check_string "Has_unclaimed_tasks" "has_unclaimed_tasks"
    (KCC.actionable_signal_label KCC.Has_unclaimed_tasks)

let test_signal_label_board () =
  check_string "Has_board_activity" "has_board_activity"
    (KCC.actionable_signal_label KCC.Has_board_activity)

let test_signal_label_discovered () =
  check_string "Has_discovered_work" "has_discovered_work"
    (KCC.actionable_signal_label KCC.Has_discovered_work)

let test_signal_label_none () =
  check_string "No_actionable_signal" "no_actionable_signal"
    (KCC.actionable_signal_label KCC.No_actionable_signal)

(* ── contract_status_label ───────────────────────────────────────────── *)

let test_status_label_tool_surface_mismatch () =
  let label =
    KCC.contract_status_label
      (KCC.Tool_surface_mismatch { missing = [ "keeper_task_claim"; "masc_broadcast" ] })
  in
  (* Label must include the missing tool names for grep-ability. *)
  check_bool "label mentions missing keeper_task_claim" true
    (Astring.String.is_infix ~affix:"keeper_task_claim" label);
  check_bool "label mentions missing masc_broadcast" true
    (Astring.String.is_infix ~affix:"masc_broadcast" label)

let test_status_label_satisfied_completion () =
  check_string "Satisfied_completion is a stable token"
    "satisfied_completion"
    (KCC.contract_status_label KCC.Satisfied_completion)

let test_status_label_satisfied_execution () =
  check_string "Satisfied_execution is a stable token"
    "satisfied_execution"
    (KCC.contract_status_label KCC.Satisfied_execution)

let test_status_label_passive_only () =
  check_string "Passive_only is a stable token"
    "passive_only"
    (KCC.contract_status_label KCC.Passive_only)

(* ── is_actionable ────────────────────────────────────────────────────── *)

let test_is_actionable_unclaimed () =
  check_bool "Has_unclaimed_tasks is actionable" true
    (KCC.is_actionable KCC.Has_unclaimed_tasks)

let test_is_actionable_board () =
  check_bool "Has_board_activity is actionable" true
    (KCC.is_actionable KCC.Has_board_activity)

let test_is_actionable_discovered () =
  check_bool "Has_discovered_work is actionable" true
    (KCC.is_actionable KCC.Has_discovered_work)

let test_is_actionable_none () =
  check_bool "No_actionable_signal is NOT actionable" false
    (KCC.is_actionable KCC.No_actionable_signal)

(* ── classify_actionable_signal: precedence ───────────────────────────── *)

let test_classify_unclaimed_wins_over_board () =
  let o = make_obs ~tasks:1 ~board:5 ~discovered:true in
  check_signal "tasks beat board+discovered" KCC.Has_unclaimed_tasks
    (KCC.classify_actionable_signal o)

let test_classify_board_wins_over_discovered () =
  let o = make_obs ~tasks:0 ~board:1 ~discovered:true in
  check_signal "board beats discovered" KCC.Has_board_activity
    (KCC.classify_actionable_signal o)

let test_classify_discovered_only () =
  let o = make_obs ~tasks:0 ~board:0 ~discovered:true in
  check_signal "discovered only" KCC.Has_discovered_work
    (KCC.classify_actionable_signal o)

let test_classify_none () =
  let o = make_obs ~tasks:0 ~board:0 ~discovered:false in
  check_signal "no signal" KCC.No_actionable_signal
    (KCC.classify_actionable_signal o)

(* ── classify_actionable_signal_for_tools: tool-aware precedence ──────── *)

let test_classify_for_tools_drops_unclaimed_no_claim_tool () =
  let o = make_obs ~tasks:5 ~board:1 ~discovered:false in
  let allowed = [ "keeper_board_post" ] in
  check_signal
    "tasks present but no claim tool → falls through to board"
    KCC.Has_board_activity
    (KCC.classify_actionable_signal_for_tools ~allowed_tool_names:allowed o)

let test_classify_for_tools_keeps_unclaimed_with_claim_tool () =
  let o = make_obs ~tasks:5 ~board:1 ~discovered:false in
  let allowed = [ "keeper_task_claim" ] in
  check_signal
    "tasks + claim tool → unclaimed wins"
    KCC.Has_unclaimed_tasks
    (KCC.classify_actionable_signal_for_tools ~allowed_tool_names:allowed o)

let test_classify_for_tools_no_actionable_when_no_tools () =
  let o = make_obs ~tasks:5 ~board:5 ~discovered:true in
  let allowed = [ "completely_unrelated_tool" ] in
  check_signal
    "no matching tool surface → no actionable signal"
    KCC.No_actionable_signal
    (KCC.classify_actionable_signal_for_tools ~allowed_tool_names:allowed o)

let test_classify_for_tools_alias_matches () =
  let o = make_obs ~tasks:1 ~board:0 ~discovered:false in
  let allowed = [ "keeper_task_claim" ] in
  let direct =
    KCC.classify_actionable_signal_for_tools ~allowed_tool_names:allowed o
  in
  let aliased =
    KCC.classify_actionable_signal_with_allowed_tools ~allowed_tool_names:allowed
      o
  in
  check_signal "alias matches direct" direct aliased

(* ── runner ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_contract_classifier_pure"
    [
      ( "actionable_signal_label",
        [
          Alcotest.test_case "Has_unclaimed_tasks" `Quick test_signal_label_unclaimed;
          Alcotest.test_case "Has_board_activity" `Quick test_signal_label_board;
          Alcotest.test_case "Has_discovered_work" `Quick test_signal_label_discovered;
          Alcotest.test_case "No_actionable_signal" `Quick test_signal_label_none;
        ] );
      ( "contract_status_label",
        [
          Alcotest.test_case "Tool_surface_mismatch carries missing names"
            `Quick test_status_label_tool_surface_mismatch;
          Alcotest.test_case "Satisfied_completion stable token" `Quick
            test_status_label_satisfied_completion;
          Alcotest.test_case "Satisfied_execution stable token" `Quick
            test_status_label_satisfied_execution;
          Alcotest.test_case "Passive_only stable token" `Quick
            test_status_label_passive_only;
        ] );
      ( "is_actionable",
        [
          Alcotest.test_case "unclaimed → true" `Quick test_is_actionable_unclaimed;
          Alcotest.test_case "board → true" `Quick test_is_actionable_board;
          Alcotest.test_case "discovered → true" `Quick test_is_actionable_discovered;
          Alcotest.test_case "none → false" `Quick test_is_actionable_none;
        ] );
      ( "classify_actionable_signal precedence",
        [
          Alcotest.test_case "tasks > board+discovered" `Quick
            test_classify_unclaimed_wins_over_board;
          Alcotest.test_case "board > discovered" `Quick
            test_classify_board_wins_over_discovered;
          Alcotest.test_case "discovered only" `Quick test_classify_discovered_only;
          Alcotest.test_case "no signal" `Quick test_classify_none;
        ] );
      ( "classify_actionable_signal_for_tools",
        [
          Alcotest.test_case "no claim tool → drops unclaimed, falls to board" `Quick
            test_classify_for_tools_drops_unclaimed_no_claim_tool;
          Alcotest.test_case "with claim tool → unclaimed wins" `Quick
            test_classify_for_tools_keeps_unclaimed_with_claim_tool;
          Alcotest.test_case "no matching tool → none" `Quick
            test_classify_for_tools_no_actionable_when_no_tools;
          Alcotest.test_case "alias matches direct" `Quick
            test_classify_for_tools_alias_matches;
        ] );
    ]

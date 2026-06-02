(** Pure-function unit tests for [Keeper_contract_classifier].

    Covers ADT label mappers, the [is_actionable] boolean projection,
    [classify_actionable_signal] precedence (unclaimed_tasks >
    board_activity), and the tool-aware variant that
    skips a signal when no matching tool is in the allowed surface. *)

open Masc_mcp
module KCC = Keeper_contract_classifier

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

(* Helper to build a [world_observation] with named fields. *)
let make_obs ~tasks ~board : KCC.world_observation =
  {
    unclaimed_task_count = tasks;
    board_activity_count = board;
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

let test_signal_label_none () =
  check_string "No_actionable_signal" "no_actionable_signal"
    (KCC.actionable_signal_label KCC.No_actionable_signal)

(* ── contract_status_label ───────────────────────────────────────────── *)

let test_status_label_tool_surface_mismatch () =
  let rendered =
    Format.asprintf "%a" KCC.pp_contract_status
      (KCC.Tool_surface_mismatch { missing = [ "keeper_task_claim"; "masc_broadcast" ] })
  in
  (* The stable label is intentionally low-cardinality; the pretty printer
     carries missing tool names for grep/debug output. *)
  check_bool "rendered status mentions missing keeper_task_claim" true
    (Astring.String.is_infix ~affix:"keeper_task_claim" rendered);
  check_bool "rendered status mentions missing masc_broadcast" true
    (Astring.String.is_infix ~affix:"masc_broadcast" rendered)

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

let test_is_actionable_none () =
  check_bool "No_actionable_signal is NOT actionable" false
    (KCC.is_actionable KCC.No_actionable_signal)

(* ── classify_actionable_signal: precedence ───────────────────────────── *)

let test_classify_unclaimed_wins_over_board () =
  let o = make_obs ~tasks:1 ~board:5 in
  check_signal "tasks beat board" KCC.Has_unclaimed_tasks
    (KCC.classify_actionable_signal o)

let test_classify_board_signal () =
  let o = make_obs ~tasks:0 ~board:1 in
  check_signal "board signal" KCC.Has_board_activity
    (KCC.classify_actionable_signal o)

let test_classify_none () =
  let o = make_obs ~tasks:0 ~board:0 in
  check_signal "no signal" KCC.No_actionable_signal
    (KCC.classify_actionable_signal o)

(* ── classify_actionable_signal_for_tools: tool-aware precedence ──────── *)

let test_classify_for_tools_drops_unclaimed_no_claim_tool () =
  let o = make_obs ~tasks:5 ~board:1 in
  let allowed = [ "keeper_board_post" ] in
  check_signal
    "tasks present but no claim tool → falls through to board"
    KCC.Has_board_activity
    (KCC.classify_actionable_signal_for_tools ~allowed_tool_names:allowed o)

let test_classify_for_tools_keeps_unclaimed_with_claim_tool () =
  let o = make_obs ~tasks:5 ~board:1 in
  let allowed = [ "keeper_task_claim" ] in
  check_signal
    "tasks + claim tool → unclaimed wins"
    KCC.Has_unclaimed_tasks
    (KCC.classify_actionable_signal_for_tools ~allowed_tool_names:allowed o)

let test_classify_for_tools_no_actionable_when_no_tools () =
  let o = make_obs ~tasks:5 ~board:5 in
  let allowed = [ "completely_unrelated_tool" ] in
  check_signal
    "no matching tool surface → no actionable signal"
    KCC.No_actionable_signal
    (KCC.classify_actionable_signal_for_tools ~allowed_tool_names:allowed o)

let test_classify_for_tools_accepts_public_aliases () =
  let claimable = make_obs ~tasks:1 ~board:0 in
  check_signal
    "prefixed public MCP claim tool supports task claim"
    KCC.Has_unclaimed_tasks
    (KCC.classify_actionable_signal_for_tools
       ~allowed_tool_names:[ "mcp__masc__masc_claim_next" ]
       claimable)

let test_requires_tool_support_for_allowed_tools_true () =
  let o = make_obs ~tasks:1 ~board:0 in
  check_bool "claimable task + claim tool requires tool-capable provider" true
    (KCC.requires_tool_support_for_allowed_tools
       ~allowed_tool_names:[ "keeper_task_claim" ] o)

let test_requires_tool_support_for_allowed_tools_false_without_matching_tool () =
  let o = make_obs ~tasks:1 ~board:0 in
  check_bool "claimable task without claim tool does not require tool support" false
    (KCC.requires_tool_support_for_allowed_tools
       ~allowed_tool_names:[ "keeper_board_post" ] o)

(* ── runner ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_contract_classifier_pure"
    [
      ( "actionable_signal_label",
        [
          Alcotest.test_case "Has_unclaimed_tasks" `Quick test_signal_label_unclaimed;
          Alcotest.test_case "Has_board_activity" `Quick test_signal_label_board;
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
          Alcotest.test_case "none → false" `Quick test_is_actionable_none;
        ] );
      ( "classify_actionable_signal precedence",
        [
          Alcotest.test_case "tasks > board" `Quick
            test_classify_unclaimed_wins_over_board;
          Alcotest.test_case "board signal" `Quick test_classify_board_signal;
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
          Alcotest.test_case "public aliases are normalized" `Quick
            test_classify_for_tools_accepts_public_aliases;
          Alcotest.test_case "matching actionable signal requires tool support"
            `Quick test_requires_tool_support_for_allowed_tools_true;
          Alcotest.test_case
            "unmatched actionable signal does not require tool support" `Quick
            test_requires_tool_support_for_allowed_tools_false_without_matching_tool;
        ] );
    ]
